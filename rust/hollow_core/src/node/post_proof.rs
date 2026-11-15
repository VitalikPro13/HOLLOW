//! Channel posts name the device that wrote them (DEVICE_PROOF_DESIGN section 13), so a
//! replica refuses what a removed device posted or edited after the server's cut,
//! whoever serves it.
//!
//! A proof covers one version of a post: the post as sent, or an edit of it. Each binds
//! the text its master signature covers, so a proof never vouches for words its device
//! did not write; a row keeps the proof of the version it holds.

use crate::crdt::operations::DevProof;
use crate::crdt::server_state::ServerState;
use crate::identity::native_identity::NativeKeypair;

use super::crypto_handler::SignedExtras;
use super::types::CardProof;
use crate::crdt::verdict::PostGate;

/// One version of a channel post as its proof reads it.
pub(crate) struct Version<'a> {
    pub sid: &'a str,
    pub cid: &'a str,
    /// The author's master.
    pub sender: &'a str,
    /// The post's own date.
    pub ts: i64,
    /// The edit's date; `None` for the post as sent.
    pub edited_at: Option<i64>,
    pub text: &'a str,
    pub x: &'a SignedExtras<'a>,
}

impl Version<'_> {
    /// The date the gate judges: an edit is content as of its own date, never older
    /// than the post it changes (else an old edit date would carry new words past the cut).
    pub(crate) fn date(&self) -> i64 {
        self.edited_at.map_or(self.ts, |e| e.max(self.ts))
    }
}

/// What the device signs: a length-prefixed digest, so no field can borrow another's
/// boundary whatever the ids and the text hold. Posts and edits sign under their own
/// domains.
fn payload(v: &Version) -> Option<String> {
    use sha2::{Digest, Sha256};
    let mid = v.x.mid.filter(|m| !m.is_empty())?;
    if !v.x.well_formed() {
        return None;
    }
    let (domain, edited_at) = match v.edited_at {
        None => ("hollow-msg-dev1", String::new()),
        Some(e) => ("hollow-edit-dev1", e.to_string()),
    };
    let order_us = v.x.order_us.map(|n| n.to_string()).unwrap_or_default();
    let ts = v.ts.to_string();
    let mut h = Sha256::new();
    for field in [
        v.sid, v.cid, v.sender, ts.as_str(), edited_at.as_str(), mid,
        v.x.reply_to.unwrap_or(""), v.x.file_id.unwrap_or(""), order_us.as_str(), v.x.album.unwrap_or(""), v.text,
    ] {
        h.update((field.len() as u64).to_le_bytes());
        h.update(field.as_bytes());
    }
    Some(format!("{domain}:{}", hex::encode(h.finalize())))
}

/// Our device's proof for a version `v.sender` (our master) signs; `None` for a post
/// with no id or a malformed slot, which the master signature refuses as well.
pub(crate) fn sign(device: &NativeKeypair, v: &Version) -> Option<Box<DevProof>> {
    use base64::Engine as _;
    let signed = payload(v)?;
    Some(Box::new(DevProof {
        device: device.peer_id(),
        sig: base64::engine::general_purpose::STANDARD.encode(device.sign(signed.as_bytes())),
    }))
}

/// Whether `sig` is `device`'s signature over `signed`, under the key its id derives.
fn signed_by(device: &str, sig: &str, signed: &str) -> bool {
    use base64::Engine as _;
    let Some(key) = crate::crypto::safety_number::pubkey_from_peer_id(device) else { return false };
    let Ok(sig) = base64::engine::general_purpose::STANDARD.decode(sig) else { return false };
    let Ok(sig) = <[u8; 64]>::try_from(sig.as_slice()) else { return false };
    let Ok(vk) = ed25519_dalek::VerifyingKey::from_bytes(&key) else { return false };
    vk.verify_strict(signed.as_bytes(), &ed25519_dalek::Signature::from_bytes(&sig)).is_ok()
}

/// The device a version's proof verifies for, under the key its id derives.
pub(crate) fn proven<'a>(dev: Option<&'a DevProof>, v: &Version) -> Option<&'a str> {
    let dev = dev?;
    signed_by(&dev.device, &dev.sig, &payload(v)?).then_some(dev.device.as_str())
}

/// `dev` when it verifies: a row keeps no proof it cannot serve back.
pub(crate) fn verified(dev: Option<Box<DevProof>>, v: &Version) -> Option<Box<DevProof>> {
    dev.filter(|d| proven(Some(d), v).is_some())
}

/// [`SignedExtras`] of a synced item as its proof reads them.
fn item_extras(item: &super::types::SyncMessageItem) -> SignedExtras<'_> {
    SignedExtras {
        mid: item.mid.as_deref(),
        reply_to: item.reply_to.as_deref(),
        file_id: item.file_id.as_deref(),
        order_us: item.order_us,
        lp_digest: None,
        album: item.album.as_deref(),
    }
}

/// The version a synced item carries: its edit when it names one.
fn item_version<'a>(sid: &'a str, cid: &'a str, item: &'a super::types::SyncMessageItem, x: &'a SignedExtras<'a>) -> Version<'a> {
    Version { sid, cid, sender: &item.s, ts: item.ts, edited_at: item.edited_at, text: &item.t, x }
}

/// The proof of a synced item when it verifies.
pub(crate) fn item_proof<'a>(sid: &str, cid: &str, item: &'a super::types::SyncMessageItem) -> Option<&'a DevProof> {
    let x = item_extras(item);
    proven(item.dev.as_deref(), &item_version(sid, cid, item, &x))?;
    item.dev.as_deref()
}

/// The gate at every ingest of a post or an edit (live, backfill, the public sync we
/// serve): true = refuse. `state` None (a guest's view) judges nothing; the caller holds
/// its own rule.
pub(crate) fn refused(state: Option<&ServerState>, v: &Version, dev: Option<&DevProof>, via: &str) -> bool {
    state.is_some_and(|s| refused_in(&s.post_gate(), v, dev, via))
}

fn refused_in(gate: &PostGate, v: &Version, dev: Option<&DevProof>, via: &str) -> bool {
    let master = super::resolver::resolve(v.sender);
    let device = proven(dev, v);
    if gate.allows(&master, device, v.date()) {
        return false;
    }
    gate.refused(&master, device, v.cid);
    hollow_log!(
        "[HOLLOW-SECURITY] REJECTED {via} {} in {}/{} by {master} dated {}: no counted device, post window or pre-cut date proves it (device {device:?})",
        if v.edited_at.is_some() { "edit" } else { "post" }, v.sid, v.cid, v.date()
    );
    true
}

/// [`refused`] for a synced item.
pub(crate) fn item_refused(gate: &PostGate, sid: &str, cid: &str, item: &super::types::SyncMessageItem, via: &str) -> bool {
    let x = item_extras(item);
    refused_in(gate, &item_version(sid, cid, item, &x), item.dev.as_deref(), via)
}

/// A change to a channel post that is no version of its words. Each kind signs under
/// its own domain, so no proof stands for another kind's change.
#[derive(Clone, Copy)]
pub(crate) enum ChangeKind<'a> {
    /// The author hides its post.
    Delete,
    /// A reaction added or removed.
    React { emoji: &'a str, add: bool },
    /// The author's card (its digest), or none (empty) when cleared.
    Card { lp_digest: &'a str },
    /// The author's file card: what the file id does not commit to ([`file_meta_digest`]).
    FileMeta { digest: &'a str },
}

/// One change as its device proof reads it.
pub(crate) struct Change<'a> {
    pub sid: &'a str,
    pub cid: &'a str,
    /// Who makes it: the post's author, or the reactor.
    pub signer: &'a str,
    pub mid: &'a str,
    /// The change's own date (a file card: its post's).
    pub at: i64,
    pub kind: ChangeKind<'a>,
}

fn change_payload(c: &Change) -> Option<String> {
    use sha2::{Digest, Sha256};
    if c.mid.is_empty() {
        return None;
    }
    let (domain, a, b) = match c.kind {
        ChangeKind::Delete => ("hollow-del-dev1", "", ""),
        ChangeKind::React { emoji, add } => ("hollow-react-dev1", emoji, if add { "add" } else { "remove" }),
        ChangeKind::Card { lp_digest } => ("hollow-card-dev1", lp_digest, ""),
        ChangeKind::FileMeta { digest } => ("hollow-filemeta-dev1", digest, ""),
    };
    let at = c.at.to_string();
    let mut h = Sha256::new();
    for field in [c.sid, c.cid, c.signer, c.mid, at.as_str(), a, b] {
        h.update((field.len() as u64).to_le_bytes());
        h.update(field.as_bytes());
    }
    Some(format!("{domain}:{}", hex::encode(h.finalize())))
}

/// Our device's proof of a change `c.signer` (our master) makes.
pub(crate) fn sign_change(device: &NativeKeypair, c: &Change) -> Option<Box<DevProof>> {
    use base64::Engine as _;
    let signed = change_payload(c)?;
    Some(Box::new(DevProof {
        device: device.peer_id(),
        sig: base64::engine::general_purpose::STANDARD.encode(device.sign(signed.as_bytes())),
    }))
}

/// [`sign_change`] for a card, carrying the date it signs.
pub(crate) fn sign_card(device: &NativeKeypair, c: &Change) -> Option<Box<CardProof>> {
    sign_change(device, c).map(|d| Box::new(CardProof { device: d.device, sig: d.sig, at: c.at }))
}

/// The device a change's proof verifies for.
pub(crate) fn change_proven<'a>(dev: Option<&'a DevProof>, c: &Change) -> Option<&'a str> {
    let dev = dev?;
    signed_by(&dev.device, &dev.sig, &change_payload(c)?).then_some(dev.device.as_str())
}

/// The post gate for a change, judged at the later of its post's date and its own
/// (`post_ts` = the held row's when we hold it): true = refuse.
pub(crate) fn change_refused(state: Option<&ServerState>, c: &Change, post_ts: i64, dev: Option<&DevProof>, via: &str) -> bool {
    state.is_some_and(|s| change_refused_in(&s.post_gate(), c, post_ts, dev, via))
}

fn change_refused_in(gate: &PostGate, c: &Change, post_ts: i64, dev: Option<&DevProof>, via: &str) -> bool {
    let master = super::resolver::resolve(c.signer);
    let device = change_proven(dev, c);
    let date = c.at.max(post_ts);
    if gate.allows(&master, device, date) {
        return false;
    }
    gate.refused(&master, device, c.cid);
    let kind = match c.kind {
        ChangeKind::Delete => "deletion",
        ChangeKind::React { .. } => "reaction",
        ChangeKind::Card { .. } => "card",
        ChangeKind::FileMeta { .. } => "file card",
    };
    hollow_log!(
        "[HOLLOW-SECURITY] REJECTED {via} {kind} on {} in {}/{} by {master} dated {date}: no counted device, post window or pre-cut date proves it (device {device:?})",
        c.mid, c.sid, c.cid
    );
    true
}

/// What a file card's proof binds beyond the file id (`file_commit` covers author, post,
/// size, hash, name, extension and video thumbnail): how it shows.
pub(crate) fn file_meta_digest(fid: &str, mime: &str, img: bool, w: Option<u32>, h: Option<u32>, thumb: Option<&str>) -> String {
    use sha2::{Digest, Sha256};
    let (img, w, h) = (u8::from(img).to_string(), w.map(|v| v.to_string()).unwrap_or_default(), h.map(|v| v.to_string()).unwrap_or_default());
    let thumb = thumb.map(|t| hex::encode(Sha256::digest(t.as_bytes()))).unwrap_or_default();
    let mut hs = Sha256::new();
    for field in [fid, mime, img.as_str(), w.as_str(), h.as_str(), thumb.as_str()] {
        hs.update((field.len() as u64).to_le_bytes());
        hs.update(field.as_bytes());
    }
    hex::encode(hs.finalize())
}

/// The digest of a synced file card.
pub(crate) fn sync_meta_digest(fm: &super::types::SyncFileMetaItem) -> String {
    file_meta_digest(&fm.fid, &fm.mime, fm.img, fm.w, fm.h, fm.thumb.as_deref())
}

/// The verified proofs of the changes a synced item carries, as a row keeps them.
pub(crate) fn item_deletion_proof<'a>(sid: &str, cid: &str, item: &'a super::types::SyncMessageItem) -> Option<&'a DevProof> {
    let (mid, at, dev) = (item.mid.as_deref()?, item.hidden_at?, item.hidden_dev.as_deref()?);
    change_proven(Some(dev), &Change { sid, cid, signer: &item.s, mid, at, kind: ChangeKind::Delete })?;
    Some(dev)
}

/// [`item_deletion_proof`] for the item's card.
pub(crate) fn item_card_proof<'a>(sid: &str, cid: &str, item: &'a super::types::SyncMessageItem) -> Option<&'a CardProof> {
    let (mid, lp, dev) = (item.mid.as_deref()?, item.lp.as_deref()?, item.lp_dev.as_deref()?);
    let digest = super::crypto_handler::link_preview_digest(lp);
    let c = Change { sid, cid, signer: &item.s, mid, at: dev.at, kind: ChangeKind::Card { lp_digest: &digest } };
    change_proven(Some(&dev.proof()), &c)?;
    Some(dev)
}

/// [`item_deletion_proof`] for one of the item's reactions.
pub(crate) fn item_reaction_proof<'a>(sid: &str, cid: &str, mid: &str, r: &'a super::types::SyncReactionItem) -> Option<&'a DevProof> {
    let dev = r.dev.as_deref()?;
    change_proven(Some(dev), &Change { sid, cid, signer: &r.p, mid, at: r.ts, kind: ChangeKind::React { emoji: &r.e, add: true } })?;
    Some(dev)
}

/// [`item_deletion_proof`] for the item's file card.
pub(crate) fn item_file_proof<'a>(sid: &str, cid: &str, item: &'a super::types::SyncMessageItem) -> Option<&'a DevProof> {
    let (mid, fm) = (item.mid.as_deref()?, item.file_meta.as_ref()?);
    let dev = fm.dev.as_deref()?;
    let digest = sync_meta_digest(fm);
    change_proven(Some(dev), &Change { sid, cid, signer: &item.s, mid, at: item.ts, kind: ChangeKind::FileMeta { digest: &digest } })?;
    Some(dev)
}

/// Section 13 over one page of channel `cid` (backfill, and the public answer we
/// serve, since a guest cannot judge): a post or edit stays only if the gate takes
/// it, and what rides it (its deletion, card, reactions, file card) only if the gate
/// takes that change too; a refused change is stripped, never the post with it.
/// Item dates stand for the post's: an item naming a post we hold with another date
/// never lands (`sync_handler::ingest_synced_channel_item_judged`).
pub(crate) fn filter_page(state: Option<&ServerState>, sid: &str, cid: &str, items: &mut Vec<super::types::SyncMessageItem>, via: &str) {
    let Some(state) = state else { return };
    let gate = state.post_gate();
    items.retain(|i| !item_refused(&gate, sid, cid, i, via));
    for item in items.iter_mut() {
        strip_refused_changes(&gate, sid, cid, item, via);
    }
}

fn strip_refused_changes(gate: &PostGate, sid: &str, cid: &str, item: &mut super::types::SyncMessageItem, via: &str) {
    let Some(mid) = item.mid.clone() else { return };
    let post_ts = item.ts;
    if let Some(at) = item.hidden_at {
        let c = Change { sid, cid, signer: &item.s, mid: &mid, at, kind: ChangeKind::Delete };
        if change_refused_in(gate, &c, post_ts, item.hidden_dev.as_deref(), via) {
            (item.hidden_at, item.hidden_sig, item.hidden_pk, item.hidden_dev) = (None, None, None, None);
        }
    }
    if let Some(lp) = item.lp.as_deref() {
        let digest = super::crypto_handler::link_preview_digest(lp);
        let proof = item.lp_dev.as_deref();
        let at = proof.map_or(post_ts, |p| p.at);
        let c = Change { sid, cid, signer: &item.s, mid: &mid, at, kind: ChangeKind::Card { lp_digest: &digest } };
        if change_refused_in(gate, &c, post_ts, proof.map(CardProof::proof).as_ref(), via) {
            // The item's signature still names the card's digest, which it keeps.
            item.lp_digest = Some(digest);
            (item.lp, item.lp_dev) = (None, None);
        }
    }
    item.reactions.retain(|r| {
        let c = Change { sid, cid, signer: &r.p, mid: &mid, at: r.ts, kind: ChangeKind::React { emoji: &r.e, add: true } };
        !change_refused_in(gate, &c, post_ts, r.dev.as_deref(), via)
    });
    if let Some(fm) = item.file_meta.as_ref() {
        let digest = sync_meta_digest(fm);
        let c = Change { sid, cid, signer: &item.s, mid: &mid, at: post_ts, kind: ChangeKind::FileMeta { digest: &digest } };
        if change_refused_in(gate, &c, post_ts, fm.dev.as_deref(), via) {
            item.file_meta = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crdt::testkeys::keys;

    fn extras<'a>(mid: &'a str, file_id: Option<&'a str>) -> SignedExtras<'a> {
        SignedExtras { mid: Some(mid), reply_to: None, file_id, order_us: Some(5_000), lp_digest: None, album: None }
    }

    fn post<'a>(c: &'a str, sender: &'a str, ts: i64, text: &'a str, x: &'a SignedExtras<'a>) -> Version<'a> {
        Version { sid: "s", cid: c, sender, ts, edited_at: None, text, x }
    }

    /// Lead decision 2: a retire's window counts every change its device proved, each at
    /// the date the gate judged it (the later of its post's and its own), and only a
    /// proof naming exactly that device, in that server, for that identity.
    #[test]
    fn lead_c_a_retires_window_counts_the_devices_change_proofs() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("m.db").to_string_lossy().into_owned();
        let store = crate::storage::MessageStore::open(&path, &"ab".repeat(32)).unwrap();
        change_proof_rows(&store);
    }

    /// A clear of ours takes the rows and every change riding them, never the window
    /// each device's proofs set: a retire after it names the same dates.
    #[test]
    fn a_clear_keeps_the_window_of_every_change_proof() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("m.db").to_string_lossy().into_owned();
        let store = crate::storage::MessageStore::open(&path, &"ab".repeat(32)).unwrap();
        let before = change_proof_rows(&store);
        store.clear_channel_history(1_000_000).unwrap();
        assert!(!store.channel_message_exists("p1") && !store.channel_message_exists("q3"), "precondition: the clear took the rows");
        let master = keys(20).1;
        let after: Vec<Option<i64>> = [21, 22, 23, 24, 26].iter().map(|t| store.newest_post_of_device("srv", &master, &keys(*t).1)).collect();
        assert_eq!(after, before, "a clear moved a retire's window");
        assert_eq!(store.newest_post_of_device("other-srv", &master, &keys(22).1), Some(9_500), "each server keeps its own");
        assert_eq!(store.newest_post_of_device("srv", &keys(25).1, &keys(24).1), Some(9_800), "each identity keeps its own");
    }

    /// The rows of `lead_c_a_retires_window_counts_the_devices_change_proofs`, checked as
    /// they land; returns the windows of devices 21, 22, 23, 24 and 26.
    fn change_proof_rows(store: &crate::storage::MessageStore) -> Vec<Option<i64>> {
        let (master, other) = (keys(20).1, keys(25).1);
        let dev = |t: u8| DevProof { device: keys(t).1, sig: "s".into() };
        let window = |t: u8| store.newest_post_of_device("srv", &master, &keys(t).1);
        let row = |sid: &str, sender: &str, mid: &str, ts: i64| {
            store.insert_channel_message(sid, "ch", sender, "w", false, ts, Some("sig"), Some("pk"), Some(mid), None, None, Some(ts * 1000), None).unwrap();
        };
        row("srv", &master, "p1", 1_000);
        store.set_channel_post_proof("p1", &dev(21)).unwrap();
        assert_eq!(window(21), Some(1_000));
        for t in [22, 23, 24, 26] {
            assert_eq!(window(t), None, "precondition: device {t} proved nothing");
        }

        store.hide_channel_message("p1", 5_000, Some("sig"), Some("pk")).unwrap();
        store.set_deletion_dev("p1", &dev(22)).unwrap();
        assert_eq!(window(22), Some(5_000), "a deletion counts at its own date");

        row("srv", &master, "p2", 2_000);
        store.set_channel_card_proof("p2", Some(&CardProof { device: keys(23).1, sig: "s".into(), at: 6_000 })).unwrap();
        assert_eq!(window(23), Some(6_000), "a card counts at its own date");

        row("srv", &other, "p3", 3_000);
        assert_eq!(store.add_reaction("p3", "+1", &master, 7_000, Some("sig"), Some("pk")), Ok(true));
        store.set_reaction_dev("p3", "+1", &master, 7_000, &dev(24)).unwrap();
        assert_eq!(window(24), Some(7_000), "a reaction on another member's post counts for the reactor");

        row("srv", &master, "p4", 8_000);
        store
            .insert_file_metadata("f4", "a", "png", "image/png", 1, 1, true, Some(1), Some(1), Some("p4"), "channel", "ch", &master, false, 8_000, None, None, None)
            .unwrap();
        store.set_file_meta_dev("f4", Some(&dev(26))).unwrap();
        assert_eq!(window(26), Some(8_000), "a file card counts at its post's date");

        // Another server, another identity's change, a lookalike id: none counts.
        row("other-srv", &master, "q1", 9_000);
        store.hide_channel_message("q1", 9_500, Some("sig"), Some("pk")).unwrap();
        store.set_deletion_dev("q1", &dev(22)).unwrap();
        row("srv", &other, "q2", 9_000);
        store.hide_channel_message("q2", 9_600, Some("sig"), Some("pk")).unwrap();
        store.set_deletion_dev("q2", &dev(22)).unwrap();
        row("srv", &master, "q3", 9_000);
        store.set_channel_card_proof("q3", Some(&CardProof { device: format!("{}x", keys(23).1), sig: "s".into(), at: 9_700 })).unwrap();
        assert_eq!(store.add_reaction("p2", "+1", &other, 9_800, Some("sig"), Some("pk")), Ok(true));
        store.set_reaction_dev("p2", "+1", &other, 9_800, &dev(24)).unwrap();
        assert_eq!((window(22), window(23), window(24)), (Some(5_000), Some(6_000), Some(7_000)), "only this server's, this identity's, this exact device's changes count");
        [21, 22, 23, 24, 26].iter().map(|t| window(*t)).collect()
    }

    /// The proof verifies only for the post it was made for (its words included), under
    /// the signing device's key, and survives a card; it needs an id and well-formed slots.
    #[test]
    fn a_post_proof_binds_the_device_and_the_posts_identity() {
        let (device, device_id, _) = keys(2);
        let (_, master, _) = keys(1);
        let x = extras("m1", None);
        let dev = sign(&device, &post("c", &master, 5, "hi", &x)).expect("a post with an id");
        assert_eq!(proven(Some(&dev), &post("c", &master, 5, "hi", &x)), Some(device_id.as_str()));
        let carded = SignedExtras { lp_digest: Some(&"a".repeat(64)), ..extras("m1", None) };
        assert!(proven(Some(&dev), &post("c", &master, 5, "hi", &carded)).is_some(), "a card keeps the proof");
        assert!(proven(Some(&dev), &post("c", &master, 5, "bye", &x)).is_none(), "other words");
        assert!(proven(Some(&dev), &post("c", &master, 6, "hi", &x)).is_none(), "another date");
        assert!(proven(Some(&dev), &post("c2", &master, 5, "hi", &x)).is_none(), "another channel");
        assert!(proven(Some(&dev), &post("c", &keys(3).1, 5, "hi", &x)).is_none(), "another author");
        assert!(proven(Some(&dev), &post("c", &master, 5, "hi", &extras("m2", None))).is_none(), "another post");
        assert!(proven(Some(&dev), &post("c", &master, 5, "hi", &extras("m1", Some("f1")))).is_none(), "another file");
        assert!(proven(Some(&dev), &Version { sid: "s:c", cid: "", ..post("c", &master, 5, "hi", &x) }).is_none(), "the place keeps its boundary");
        let claimed = DevProof { device: keys(4).1, sig: dev.sig.clone() };
        assert!(proven(Some(&claimed), &post("c", &master, 5, "hi", &x)).is_none(), "a proof names the key that made it");
        let no_id = SignedExtras { mid: None, ..extras("m1", None) };
        assert!(sign(&device, &post("c", &master, 5, "hi", &no_id)).is_none(), "no id, no proof");
        assert!(sign(&device, &post("c", &master, 5, "hi", &extras("m:1", None))).is_none(), "a malformed id");
    }

    /// An edit's proof covers that edit alone: its words, its date and the post it
    /// changes; a post's proof never stands for an edit, nor one edit's for another.
    #[test]
    fn an_edit_proof_binds_the_edits_words_and_date() {
        let (device, device_id, _) = keys(2);
        let (_, master, _) = keys(1);
        let x = extras("m1", None);
        let edit = |at: i64, text: &'static str| Version { edited_at: Some(at), text, ..post("c", &master, 5, "", &x) };
        let dev = sign(&device, &edit(9, "new")).expect("an edit with an id");
        assert_eq!(proven(Some(&dev), &edit(9, "new")), Some(device_id.as_str()));
        assert!(proven(Some(&dev), &edit(9, "other")).is_none(), "other words");
        assert!(proven(Some(&dev), &edit(10, "new")).is_none(), "another edit date");
        assert!(proven(Some(&dev), &Version { ts: 6, ..edit(9, "new") }).is_none(), "another post date");
        assert!(proven(Some(&dev), &post("c", &master, 5, "new", &x)).is_none(), "an edit's proof is no post's");
        let posted = sign(&device, &post("c", &master, 5, "new", &x)).unwrap();
        assert!(proven(Some(&posted), &edit(9, "new")).is_none(), "a post's proof is no edit's");
        assert!(payload(&edit(9, "new")).is_some_and(|p| p.starts_with("hollow-edit-dev1:")), "an edit signs under its own domain");
        assert!(payload(&post("c", &master, 5, "new", &x)).is_some_and(|p| p.starts_with("hollow-msg-dev1:")), "a post signs under its own domain");
        assert_eq!(edit(9, "new").date(), 9);
        assert_eq!(edit(3, "new").date(), 5, "an edit dated before its post is judged at the post's date");
    }

    /// A server master 20 owns, whose view counts its device 21 and has removed 22.
    fn cut_state(cut: bool) -> ServerState {
        use crate::crdt::authority::{AuthorityView, ViewEntry};
        let mut s = ServerState::new("srv".into(), "s".into(), keys(20).1);
        let auth = crate::identity::roster::Authority {
            key: "k".into(),
            counted: [keys(21).1].into(),
            removed: [(keys(22).1, keys(21).1)].into(),
            ..Default::default()
        };
        let mut v = AuthorityView::judging();
        v.insert(keys(20).1, ViewEntry { key: Some("k".into()), auth: Some(auth) });
        s.authority = std::sync::Arc::new(v);
        s.cut = cut;
        s
    }

    fn item(mid: &str, by: Option<u8>) -> super::super::types::SyncMessageItem {
        let master = keys(20).1;
        let x = extras(mid, None);
        let mut it: super::super::types::SyncMessageItem = serde_json::from_value(serde_json::json!({ "s": master, "t": "hi", "ts": 7, "mid": mid, "order_us": 5_000 })).unwrap();
        it.dev = by.and_then(|t| sign(&keys(t).0, &Version { sid: "srv", cid: "ch", sender: &master, ts: 7, edited_at: None, text: "hi", x: &x }));
        it
    }

    /// The backfill layer: past the cut a page keeps only posts a counted device proves.
    #[test]
    fn a_backfilled_page_keeps_only_posts_a_counted_device_proves() {
        let page = || vec![item("a", Some(21)), item("b", Some(22)), item("c", None)];
        let kept = |state: &ServerState| {
            let mut p = page();
            super::super::crypto_handler::backfill_filter(Some(state), "ch", &mut p);
            p.into_iter().filter_map(|i| i.mid).collect::<Vec<_>>()
        };
        assert_eq!(kept(&cut_state(true)), vec!["a".to_string()]);
        assert_eq!(kept(&cut_state(false)), vec!["a".to_string(), "b".to_string(), "c".to_string()], "before the cut nothing is judged");
        let mut p = page();
        super::super::crypto_handler::backfill_filter(Some(&cut_state(true)), "other", &mut p);
        assert!(p.is_empty(), "a proof made for another channel proves nothing here");
    }

    /// The live layer: a removed device's post neither stores nor shows; a counted one's
    /// row keeps its proof, which the sync answer serves back, and a retire reads its date.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn a_live_post_is_judged_and_its_row_keeps_the_proof() {
        use super::super::message_ops::{handle_envelope_channel_message, SlowModeClock};
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("m.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let (master_kp, master, _) = keys(20);
        let state = cut_state(true);
        let (tx, mut rx) = tokio::sync::mpsc::channel(16);
        for (mid, by, ts) in [("ok", 21u8, 1_000i64), ("gone", 22, 2_000), ("later", 21, 900)] {
            use base64::Engine as _;
            let pk = base64::engine::general_purpose::STANDARD.encode(master_kp.public_key_protobuf());
            let x = SignedExtras { mid: Some(mid), reply_to: None, file_id: None, order_us: Some(ts * 1000), lp_digest: None, album: None };
            let (sig, pk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, ts, &x, "hello");
            let dev = sign(&keys(by).0, &Version { sid: "srv", cid: "ch", sender: &master, ts, edited_at: None, text: "hello", x: &x });
            handle_envelope_channel_message(
                &tx, &master_kp, Some(&state), &mut SlowModeClock::default(), &keys(30).1, master.clone(), "srv".into(), "ch".into(),
                "hello".into(), ts, sig, pk, Some(mid.into()), None, None, None, Some(ts * 1000), None, dev, &path, &pass,
            )
            .await;
        }
        {
            use base64::Engine as _;
            let pk = base64::engine::general_purpose::STANDARD.encode(master_kp.public_key_protobuf());
            let x = SignedExtras { mid: Some("junk"), reply_to: None, file_id: None, order_us: Some(800_000), lp_digest: None, album: None };
            let (sig, pk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, 800, &x, "hello");
            let forged = sign(&keys(22).0, &Version { sid: "srv", cid: "ch", sender: &master, ts: 800, edited_at: None, text: "hello", x: &x }).map(|d| Box::new(DevProof { device: keys(21).1, sig: d.sig }));
            handle_envelope_channel_message(
                &tx, &master_kp, Some(&cut_state(false)), &mut SlowModeClock::default(), &keys(30).1, master.clone(), "srv".into(), "ch".into(),
                "hello".into(), 800, sig, pk, Some("junk".into()), None, None, None, Some(800_000), None, forged, &path, &pass,
            )
            .await;
        }
        let mut shown = Vec::new();
        while let Ok(e) = rx.try_recv() {
            if let crate::node::NetworkEvent::ChannelMessageReceived { message_id, .. } = e {
                shown.push(message_id);
            }
        }
        assert_eq!(shown, vec!["ok".to_string(), "later".to_string(), "junk".to_string()]);
        let store = crate::storage::MessageStore::open(&path, &pass).unwrap();
        assert!(!store.channel_message_exists("gone"), "a removed device's post is not stored");
        let rows = store.get_visible_channel_messages_before("srv", "ch", i64::MAX, 10).unwrap();
        let page = super::super::sync_handler::channel_sync_items(&store, &rows);
        let served: Vec<(Option<String>, Option<String>)> = page.items.iter().map(|i| (i.mid.clone(), i.dev.as_ref().map(|d| d.device.clone()))).collect();
        assert!(served.iter().all(|(mid, d)| if mid.as_deref() == Some("junk") { d.is_none() } else { d.as_deref() == Some(keys(21).1.as_str()) }), "the sync answer serves each proof back, and no forged one: {served:?}");
        assert_eq!(store.newest_post_of_device("srv", &master, &keys(21).1), Some(1_000), "a retire's window is the newest proven post");
        assert_eq!(store.newest_post_of_device("srv", &master, &keys(22).1), None);
        store.set_channel_post_proof("ok", &DevProof { device: keys(22).1, sig: "x".into() }).unwrap();
        assert_eq!(store.channel_post_proofs(&["ok"]).get("ok").map(|d| d.device.clone()), Some(keys(21).1), "a row keeps its first proof");
    }

    /// The live edit layer: a row keeps the proof of the version it holds. An edit's
    /// verified proof replaces the post's, an unproven edit leaves none, and past the cut a
    /// removed device's edit is refused while a counted one's lands.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn a_live_edit_keeps_only_its_own_proof() {
        use super::super::message_ops::{handle_envelope_channel_message, handle_envelope_edit_message, SlowModeClock};
        use base64::Engine as _;
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("m.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let (master_kp, master, _) = keys(20);
        let pk = base64::engine::general_purpose::STANDARD.encode(master_kp.public_key_protobuf());
        let x = SignedExtras { mid: Some("p"), reply_to: None, file_id: None, order_us: Some(1_000_000), lp_digest: None, album: None };
        let (tx, _rx) = tokio::sync::mpsc::channel(64);
        let open = || crate::storage::MessageStore::open(&path, &pass).unwrap();
        let (sig, spk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, 1_000, &x, "hello");
        let dev = sign(&keys(21).0, &Version { sid: "srv", cid: "ch", sender: &master, ts: 1_000, edited_at: None, text: "hello", x: &x });
        handle_envelope_channel_message(
            &tx, &master_kp, Some(&cut_state(false)), &mut SlowModeClock::default(), &keys(30).1, master.clone(), "srv".into(), "ch".into(),
            "hello".into(), 1_000, sig, spk, Some("p".into()), None, None, None, Some(1_000_000), None, dev, &path, &pass,
        )
        .await;
        let proof = || open().channel_post_proofs(&["p"]).get("p").map(|d| d.device.clone());
        let text = || open().get_channel_message_sig_row("p").map(|r| r.text);
        assert_eq!(proof(), Some(keys(21).1));
        let edit = async |state: &ServerState, at: i64, words: &str, by: Option<u8>, claim: Option<u8>| {
            let (sig, spk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, at, &x, words);
            let v = Version { sid: "srv", cid: "ch", sender: &master, ts: 1_000, edited_at: Some(at), text: words, x: &x };
            let dev = by.and_then(|t| sign(&keys(t).0, &v)).map(|d| Box::new(DevProof { device: claim.map_or(d.device.clone(), |c| keys(c).1), sig: d.sig }));
            handle_envelope_edit_message(&tx, &master_kp, Some(state), &master, "p".into(), words.into(), at, sig, spk, Some("srv".into()), Some("ch".into()), dev, &path, &pass).await;
        };
        edit(&cut_state(false), 2_000, "forged", Some(22), Some(21)).await;
        assert_eq!(text().as_deref(), Some("forged"), "before the cut nothing is judged");
        assert_eq!(proof(), None, "an edit with no proof of its own leaves the row none");
        edit(&cut_state(false), 3_000, "by 22", Some(22), None).await;
        assert_eq!(proof(), Some(keys(22).1), "the edit's proof replaces the post's");
        assert_eq!(open().newest_post_of_device("srv", &master, &keys(22).1), Some(3_000), "a retire counts the edit's date");
        edit(&cut_state(true), 4_000, "removed", Some(22), None).await;
        assert_eq!(text().as_deref(), Some("by 22"), "a removed device's edit past the cut");
        edit(&cut_state(true), 5_000, "counted", Some(21), None).await;
        assert_eq!(text().as_deref(), Some("counted"), "a counted device's edit past the cut");
        assert_eq!(proof(), Some(keys(21).1));
    }

    /// REVIEW-C: `cut_state` with a stamped base whose lineage cut clock is `cut_ms`.
    fn cut_state_with_clock(cut_ms: u64) -> ServerState {
        use crate::crdt::hlc::HlcTimestamp;
        let mut s = cut_state(true);
        let at = HlcTimestamp { physical_ms: cut_ms, counter: 0, actor: keys(20).1 };
        let mut b = ServerState::new("srv".into(), "s".into(), keys(20).1);
        b.cp_stamped = true;
        b.cp_cut = Some(at.clone());
        s.base = Some(Box::new(crate::crdt::fold::Base { hash: [7; 32], hlc: at.clone(), covers: at, generation: 1, parent: None, state: std::sync::Arc::new(b) }));
        s
    }

    /// REVIEW-C F1: an edit of a post we hold is content as of max(post date, edit date)
    /// (section 13 build notes), whoever carries it. The live arm reads the post date
    /// from our row; a backfilled edit must too, never the date its item claims.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn review_c_a_backfilled_edit_of_a_held_post_is_judged_at_the_held_posts_date() {
        use base64::Engine as _;
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("m.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let (master_kp, master, _) = keys(20);
        let pk = base64::engine::general_purpose::STANDARD.encode(master_kp.public_key_protobuf());
        let state = cut_state_with_clock(10_000);
        assert!(state.post_allowed(&master, None, 9_999) && !state.post_allowed(&master, None, 50_000), "precondition: rule 3 at 10_000");
        // An honest post dated after the cut, proven by the counted device 21.
        let x = SignedExtras { mid: Some("p"), reply_to: None, file_id: None, order_us: Some(50_000_000), lp_digest: None, album: None };
        let (sig, spk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, 50_000, &x, "hello");
        let dev = sign(&keys(21).0, &Version { sid: "srv", cid: "ch", sender: &master, ts: 50_000, edited_at: None, text: "hello", x: &x });
        let (tx, _rx) = tokio::sync::mpsc::channel(64);
        super::super::message_ops::handle_envelope_channel_message(
            &tx, &master_kp, Some(&state), &mut super::super::message_ops::SlowModeClock::default(), &keys(30).1, master.clone(), "srv".into(), "ch".into(),
            "hello".into(), 50_000, sig, spk, Some("p".into()), None, None, None, Some(50_000_000), None, dev, &path, &pass,
        )
        .await;
        let text = || crate::storage::MessageStore::open(&path, &pass).unwrap().get_channel_message_sig_row("p").map(|r| r.text);
        assert_eq!(text().as_deref(), Some("hello"), "precondition: the post is held");

        // Live: an edit with no device proof dated before the cut is judged at the post's date.
        let (esig, epk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, 6_000, &x, "live words");
        super::super::message_ops::handle_envelope_edit_message(&tx, &master_kp, Some(&state), &master, "p".into(), "live words".into(), 6_000, esig, epk, Some("srv".into()), Some("ch".into()), None, &path, &pass).await;
        assert_eq!(text().as_deref(), Some("hello"), "precondition: the live arm refuses it");

        // Backfill: the same kind of edit, its item claiming a post date before the cut.
        let (bsig, bpk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, 6_000, &x, "new words");
        let it: super::super::types::SyncMessageItem = serde_json::from_value(serde_json::json!({
            "s": master, "t": "new words", "ts": 5_000, "mid": "p", "order_us": 50_000_000, "edited_at": 6_000, "sig": bsig, "pk": bpk,
        }))
        .unwrap();
        let mut page = vec![it];
        super::super::crypto_handler::backfill_filter(Some(&state), "ch", &mut page);
        {
            let store = crate::storage::MessageStore::open(&path, &pass).unwrap();
            for item in &page {
                let _ = super::super::sync_handler::ingest_synced_channel_item(&store, "srv", "ch", item, &keys(30).1, &mut super::super::crypto_handler::PkCache::new());
            }
        }
        assert_eq!(text().as_deref(), Some("hello"), "a backfilled edit claiming an old post date rewrote a post written after the cut (page kept {})", page.len());
    }

    /// A proof-less live post dated after the cut (a 0.13 sender) is refused live too
    /// (decided 11-06: 0.14 is a clean break; the RED 0.13 notice says to update).
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_013_members_proofless_live_post_after_the_cut_is_refused() {
        use base64::Engine as _;
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("m.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let (master_kp, master, _) = keys(20);
        let pk = base64::engine::general_purpose::STANDARD.encode(master_kp.public_key_protobuf());
        let state = cut_state_with_clock(10_000);
        let x = SignedExtras { mid: Some("old"), reply_to: None, file_id: None, order_us: Some(50_000_000), lp_digest: None, album: None };
        let (sig, spk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, 50_000, &x, "from 0.13");
        let (tx, _rx) = tokio::sync::mpsc::channel(64);
        super::super::message_ops::handle_envelope_channel_message(
            &tx, &master_kp, Some(&state), &mut super::super::message_ops::SlowModeClock::default(), &keys(30).1, master.clone(), "srv".into(), "ch".into(),
            "from 0.13".into(), 50_000, sig, spk, Some("old".into()), None, None, None, Some(50_000_000), None, None, &path, &pass,
        )
        .await;
        assert!(!crate::storage::MessageStore::open(&path, &pass).unwrap().channel_message_exists("old"), "a proof-less live post after the cut landed");
    }

    /// Every change riding a page is judged on its own: past the cut a removed device's
    /// deletion, card, reaction or file card is stripped (the post stays), a counted
    /// device's stays, and a proof made for another kind or post proves nothing.
    #[test]
    fn a_page_keeps_only_changes_a_counted_device_proves() {
        let master = keys(20).1;
        let change = |tag: u8, kind: ChangeKind| sign_change(&keys(tag).0, &Change { sid: "srv", cid: "ch", signer: &master, mid: "a", at: 9, kind });
        let lp = crate::node::LinkPreviewRef {
            url: "https://example.com/".into(), title: "t".into(), description: String::new(), domain: "example.com".into(), site_name: String::new(),
            thumb_webp_b64: None, thumb_w: None, thumb_h: None, rich: None,
        };
        let digest = super::super::crypto_handler::link_preview_digest(&lp);
        let fm: super::super::types::SyncFileMetaItem = serde_json::from_value(serde_json::json!({
            "fid": "f", "name": "n", "ext": "png", "mime": "image/png", "size": 1, "img": true, "ts": 7, "sender": master,
        }))
        .unwrap();
        let meta = sync_meta_digest(&fm);
        let page = |by: u8| {
            let mut it = item("a", Some(21));
            (it.hidden_at, it.hidden_dev) = (Some(9), change(by, ChangeKind::Delete));
            it.lp = Some(Box::new(lp.clone()));
            it.lp_dev = sign_card(&keys(by).0, &Change { sid: "srv", cid: "ch", signer: &master, mid: "a", at: 9, kind: ChangeKind::Card { lp_digest: &digest } });
            let react = |tag: Option<u8>, e: &str| super::super::types::SyncReactionItem {
                e: e.into(), p: master.clone(), ts: 9, sig: None, pk: None,
                dev: tag.and_then(|t| sign_change(&keys(t).0, &Change { sid: "srv", cid: "ch", signer: &master, mid: "a", at: 9, kind: ChangeKind::React { emoji: e, add: true } })),
            };
            it.reactions = vec![react(Some(by), "r1"), react(None, "r2"), react(Some(21), "r3")];
            it.reactions[2].dev = change(21, ChangeKind::Delete);
            let mut fm = fm.clone();
            fm.dev = sign_change(&keys(by).0, &Change { sid: "srv", cid: "ch", signer: &master, mid: "a", at: 7, kind: ChangeKind::FileMeta { digest: &meta } });
            it.file_meta = Some(fm);
            vec![it]
        };
        let judged = |state: &ServerState, by: u8| {
            let mut p = page(by);
            filter_page(Some(state), "srv", "ch", &mut p, "test");
            let it = p.pop().expect("the post stays");
            (it.hidden_at.is_some(), it.lp.is_some(), it.reactions.iter().map(|r| r.e.clone()).collect::<Vec<_>>(), it.file_meta.is_some(), it.lp_digest)
        };
        let (hidden, carded, reactions, filed, lp_digest) = judged(&cut_state(true), 22);
        assert!(!hidden && !carded && !filed && reactions.is_empty(), "a removed device's changes past the cut");
        assert_eq!(lp_digest.as_deref(), Some(digest.as_str()), "a stripped card leaves the digest its post's signature names");
        assert_eq!(judged(&cut_state(true), 21), (true, true, vec!["r1".to_string()], true, None), "a counted device's changes; a proof of another kind proves nothing");
        assert_eq!(judged(&cut_state(false), 22).2.len(), 3, "before the cut nothing is judged");
        assert!(payload_domains_differ(), "each kind signs under its own domain");
    }

    fn payload_domains_differ() -> bool {
        let c = |kind| change_payload(&Change { sid: "s", cid: "c", signer: "m", mid: "x", at: 1, kind }).unwrap()[..12].to_string();
        let all = [c(ChangeKind::Delete), c(ChangeKind::React { emoji: "", add: true }), c(ChangeKind::Card { lp_digest: "" }), c(ChangeKind::FileMeta { digest: "" })];
        all.iter().collect::<std::collections::HashSet<_>>().len() == all.len()
    }

    /// A file card a device proof holds is never swapped for a proof-less one, whoever
    /// signs the item; a proven card for the same file replaces it and keeps its proof.
    #[test]
    fn a_proven_file_card_is_never_swapped_for_a_proofless_one() {
        let store = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        store.insert_file_metadata("f", "n", "png", "image/png", 1, 0, true, Some(4), Some(4), Some("a"), "channel", "srv:ch", &keys(20).1, false, 7, None, None, None).unwrap();
        let digest = super::super::post_proof::file_meta_digest("f", "image/png", true, Some(4), Some(4), None);
        let dev = DevProof { device: keys(21).1, sig: "s".into() };
        super::super::file_handler::keep_meta_proof(&store, "f", &digest, Some(&dev));
        assert!(super::super::file_handler::meta_swap_refused(&store, "f", false), "a proof-less card over a proven one");
        assert!(!super::super::file_handler::meta_swap_refused(&store, "f", true));
        super::super::file_handler::keep_meta_proof(&store, "f", "another digest", Some(&dev));
        assert!(!super::super::file_handler::meta_swap_refused(&store, "f", false), "a proof for another card is never kept");
    }

    /// A live file card is judged like a post's change: a removed device's past the cut
    /// is refused, a counted one's kept with its proof, nothing judged with no place.
    #[test]
    fn a_live_file_card_needs_a_counted_device_past_the_cut() {
        let store = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        let states = std::collections::HashMap::from([("srv".to_string(), cut_state(true))]);
        let master = keys(20).1;
        let judged = |tag: u8| {
            let dev = sign_change(&keys(tag).0, &Change { sid: "srv", cid: "ch", signer: &master, mid: "a", at: 7, kind: ChangeKind::FileMeta { digest: "d" } });
            super::super::file_handler::header_meta_judged(&store, &states, Some((("srv", "ch"), "a")), &master, 7, "d", dev, None)
        };
        assert!(judged(22).is_err(), "a removed device's file card");
        assert_eq!(judged(21).ok().flatten().map(|d| d.device), Some(keys(21).1));
        assert!(super::super::file_handler::header_meta_judged(&store, &states, None, &master, 7, "d", None, None).is_ok());
    }

    /// An answer to our pull that serves no proof (a 0.13 holder) is judged by the proof
    /// we keep, which counts only for the very card it signs; an unasked header gets no
    /// such help, and a wrong proof is refused, never swapped for ours.
    #[test]
    fn a_pulled_card_without_a_proof_is_judged_by_the_proof_we_keep() {
        use super::super::file_handler::{header_meta_judged, keep_meta_proof};
        let store = crate::storage::MessageStore::open(":memory:", &"ab".repeat(32)).unwrap();
        let states = std::collections::HashMap::from([("srv".to_string(), cut_state(true))]);
        let master = keys(20).1;
        store.insert_file_metadata("f", "n", "png", "image/png", 1, 0, true, Some(4), Some(4), Some("a"), "channel", "srv:ch", &master, false, 7, None, None, None).unwrap();
        let digest = file_meta_digest("f", "image/png", true, Some(4), Some(4), None);
        let kept = sign_change(&keys(21).0, &Change { sid: "srv", cid: "ch", signer: &master, mid: "a", at: 7, kind: ChangeKind::FileMeta { digest: &digest } });
        keep_meta_proof(&store, "f", &digest, kept.as_deref());
        let judged = |digest: &str, ts: i64, dev: Option<Box<DevProof>>, pulled: Option<&str>| {
            header_meta_judged(&store, &states, Some((("srv", "ch"), "a")), &master, ts, digest, dev, pulled)
        };
        assert_eq!(judged(&digest, 7, None, Some("f")).ok().flatten(), kept, "the kept proof judges a proof-less answer");
        assert!(judged(&digest, 7, None, None).is_err(), "an unasked proof-less card");
        assert!(judged("another digest", 7, None, Some("f")).is_err(), "the kept proof signs another card");
        assert!(judged(&digest, 8, None, Some("f")).is_err(), "the kept proof signs another date");
        let mut wrong = kept.clone().expect("a proof");
        let swapped = if wrong.sig.starts_with('a') { "b" } else { "a" };
        wrong.sig.replace_range(..1, swapped);
        assert!(judged(&digest, 7, Some(wrong), Some("f")).is_err(), "a wrong proof is refused, never swapped for ours");
    }

    /// A row that holds no proof takes the proof of the version it holds when that
    /// arrives again, live or by backfill, never a proof of another version.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn a_held_row_takes_a_proof_of_its_own_version() {
        use base64::Engine as _;
        let _g = crate::node::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("m.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let (master_kp, master, _) = keys(20);
        let pk = base64::engine::general_purpose::STANDARD.encode(master_kp.public_key_protobuf());
        let (tx, _rx) = tokio::sync::mpsc::channel(64);
        let open = || crate::storage::MessageStore::open(&path, &pass).unwrap();
        let proof = |mid: &str| open().channel_post_proofs(&[mid]).get(mid).map(|d| d.device.clone());
        for mid in ["live", "synced"] {
            let x = SignedExtras { mid: Some(mid), reply_to: None, file_id: None, order_us: Some(1_000_000), lp_digest: None, album: None };
            let (sig, spk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, 1_000, &x, "hi");
            super::super::message_ops::handle_envelope_channel_message(
                &tx, &master_kp, None, &mut super::super::message_ops::SlowModeClock::default(), &keys(30).1, master.clone(), "srv".into(), "ch".into(),
                "hi".into(), 1_000, sig, spk, Some(mid.into()), None, None, None, Some(1_000_000), None, None, &path, &pass,
            )
            .await;
        }
        assert_eq!((proof("live"), proof("synced")), (None, None), "precondition: rows without proofs");
        let x = SignedExtras { mid: Some("live"), reply_to: None, file_id: None, order_us: Some(1_000_000), lp_digest: None, album: None };
        let (sig, spk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, 1_000, &x, "hi");
        let dev = sign(&keys(21).0, &Version { sid: "srv", cid: "ch", sender: &master, ts: 1_000, edited_at: None, text: "hi", x: &x });
        super::super::message_ops::handle_envelope_channel_message(
            &tx, &master_kp, None, &mut super::super::message_ops::SlowModeClock::default(), &keys(30).1, master.clone(), "srv".into(), "ch".into(),
            "hi".into(), 1_000, sig, spk, Some("live".into()), None, None, None, Some(1_000_000), None, dev, &path, &pass,
        )
        .await;
        assert_eq!(proof("live"), Some(keys(21).1), "a live duplicate gives the row its proof");
        let x = SignedExtras { mid: Some("synced"), reply_to: None, file_id: None, order_us: Some(1_000_000), lp_digest: None, album: None };
        let (sig, spk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, 1_000, &x, "hi");
        let mut it: super::super::types::SyncMessageItem =
            serde_json::from_value(serde_json::json!({ "s": master, "t": "hi", "ts": 1_000, "mid": "synced", "order_us": 1_000_000, "sig": sig, "pk": spk })).unwrap();
        it.dev = sign(&keys(21).0, &Version { sid: "srv", cid: "ch", sender: &master, ts: 1_000, edited_at: None, text: "other", x: &x });
        let ingest = |it: &super::super::types::SyncMessageItem| {
            super::super::sync_handler::ingest_synced_channel_item(&open(), "srv", "ch", it, &keys(30).1, &mut super::super::crypto_handler::PkCache::new());
        };
        ingest(&it);
        assert_eq!(proof("synced"), None, "a proof of another version is never kept");
        it.dev = sign(&keys(21).0, &Version { sid: "srv", cid: "ch", sender: &master, ts: 1_000, edited_at: None, text: "hi", x: &x });
        ingest(&it);
        assert_eq!(proof("synced"), Some(keys(21).1), "a backfilled duplicate gives the row its proof");
        // The row now holds an edit: the post's own proof no longer speaks for it.
        let x = SignedExtras { mid: Some("edited"), reply_to: None, file_id: None, order_us: Some(1_000_000), lp_digest: None, album: None };
        let (sig, spk) = super::super::crypto_handler::sign_message_versioned(&master_kp, &pk, "ch", "srv:ch", &master, 1_000, &x, "hi");
        open().insert_channel_message("srv", "ch", &master, "hi", false, 1_000, sig.as_deref(), spk.as_deref(), Some("edited"), None, None, Some(1_000_000), None).unwrap();
        open().edit_channel_message("edited", "changed", 2_000, None, None, None).unwrap();
        let mut it: super::super::types::SyncMessageItem =
            serde_json::from_value(serde_json::json!({ "s": master, "t": "hi", "ts": 1_000, "mid": "edited", "order_us": 1_000_000, "sig": sig, "pk": spk })).unwrap();
        it.dev = sign(&keys(21).0, &Version { sid: "srv", cid: "ch", sender: &master, ts: 1_000, edited_at: None, text: "hi", x: &x });
        ingest(&it);
        assert_eq!(proof("edited"), None, "a proof of the post as sent is never kept on its edit");
    }

    /// Every post this node sends carries its device's proof and every row it stores
    /// keeps one: a site without it leaves posts no replica past the cut takes in.
    #[test]
    fn every_post_send_and_store_site_keeps_the_proof() {
        let node = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src").join("node");
        for (file, sends_here, stores) in [("message_ops.rs", true, 2), ("file_handler.rs", true, 1), ("sync_handler.rs", false, 2), ("fetch.rs", false, 1)] {
            let src = std::fs::read_to_string(node.join(file)).expect("read node source").replace("\r\n", "\n");
            let prod = &src[..src.find("\n#[cfg(test)]\nmod tests").unwrap_or(src.len())];
            let sends = prod.matches("ChannelMessagePayload {\n").count() + prod.matches("HavenMessage::PublicChannelMessage {\n").count();
            assert!(!sends_here || (sends > 0 && prod.matches("dev: dev.clone(),").count() == sends), "{file}: a post leaves without its proof");
            assert_eq!(prod.matches("set_channel_post_proof(").count(), stores, "{file}: a stored post drops its proof");
        }
        let ops = std::fs::read_to_string(node.join("message_ops.rs")).expect("read node source").replace("\r\n", "\n");
        let edit = &ops[ops.find("pub(crate) async fn handle_edit_channel_message(").expect("the edit sender")..];
        let edit = &edit[..edit.find("\n}\n").unwrap_or(edit.len())];
        assert!(edit.contains("post_proof::sign("), "an edit leaves without its device's proof");
        assert_eq!(edit.matches("dev: edev.clone(),").count(), 2, "an edit envelope leaves without its proof");
        for sender in ["handle_delete_channel_message(", "handle_add_channel_reaction(", "handle_remove_channel_reaction(", "handle_attach_channel_link_preview("] {
            let body = &ops[ops.find(&format!("pub(crate) async fn {sender}")).expect("a change sender")..];
            let body = &body[..body.find("\n}\n").unwrap_or(body.len())];
            assert!(["sign_change(", "sign_card(", "reaction_proof("].iter().any(|s| body.contains(s)), "{sender}: a change leaves without its device's proof");
            assert_eq!(body.matches("dev: cdev.clone(),").count(), 2, "{sender}: a change envelope leaves without its proof");
        }
        let fetch = std::fs::read_to_string(node.join("fetch.rs")).expect("read node source").replace("\r\n", "\n");
        let fetch = &fetch[..fetch.find("\n#[cfg(test)]\nmod tests").unwrap_or(fetch.len())];
        assert_eq!(fetch.matches(") == Some(ChannelInsert::Cleared)").count(), 2, "fetch.rs: a channel insert site the guard does not know");
        assert_eq!(fetch.matches("link_preview.as_ref(), dev.as_deref(),\n").count(), 2, "fetch.rs: a fetched post drops its proof");
    }
}

