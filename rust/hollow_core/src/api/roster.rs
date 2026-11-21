//! The roster and the recovery phrase from Dart (design ID-1). The phrase becomes keys
//! here, signs, and is dropped: nothing stores it, and the recovery key never reaches
//! the node, which only hears that the roster changed.

use flutter_rust_bridge::frb;

use crate::identity::native_identity::NativeKeypair;
use crate::identity::roster::REMOVAL_GRACE_MS;
use crate::node::NodeCommand;
use crate::storage::MessageStore;

/// One device the roster knows about, for the Devices page.
pub struct RosterDevice {
    pub device_peer_id: String,
    /// `member`, `pending` or `removed`.
    pub state: String,
    pub this_device: bool,
    /// When this device first saw a pending join (its seven days run from here).
    pub first_seen_ms: Option<i64>,
    /// Members this device added: removing it keeps them unless they go too.
    pub added: Vec<String>,
}

/// What our own roster says, for the Devices page and the lock screens.
pub struct RosterStatus {
    /// This device belongs to the identity.
    pub member: bool,
    /// The recovery phrase is the root (a recovery exists).
    pub protected: bool,
    /// A device restored from a backup may join by nobody refusing it for seven days.
    /// Only the phrase changes it.
    pub backup_wait: bool,
    /// This device asked to join and waits: when it becomes a member without anyone
    /// answering, on this device's clock.
    pub joins_at_ms: Option<i64>,
    /// This device was removed: by whom, and when it erases itself.
    pub removed_by: Option<String>,
    pub wipe_at_ms: Option<i64>,
    pub devices: Vec<RosterDevice>,
    /// This device is not a member although the phrase admitted it (`"admit"`) or a
    /// recovery kept it (`"recover"`): that statement is dated at or before the current
    /// base (a clock behind, or a later change). The lock's button runs
    /// `join_with_phrase`, or `recover_with_phrase(keep: [], too_early_lost_since_ms)`.
    pub too_early: Option<String>,
    /// For `too_early == "recover"`: when that recovery said the person last had the
    /// devices it dropped.
    pub too_early_lost_since_ms: Option<i64>,
    /// This device is not a member because a recovery typed elsewhere left it out:
    /// that recovery's time.
    pub dropped_by_recovery_at_ms: Option<i64>,
}

/// What a Welcome phrase restore that minted this device left for the Home card.
pub struct WelcomeRestoreState {
    pub at_ms: i64,
    /// `"admit"` (No) or `"recover"` (Yes).
    pub branch: String,
    /// The restore found no roster here (a fresh install).
    pub empty: bool,
    /// The identity's roster says a device restored from a backup joins only when
    /// approved.
    pub no_wait: bool,
}

/// The Home card's state, `None` when no Welcome restore minted THIS device or its 30
/// days are over.
#[frb]
pub fn welcome_restore_state() -> Result<Option<WelcomeRestoreState>, String> {
    let c = ctx()?;
    let store = MessageStore::open(&c.db_path, &c.db_passphrase)?;
    let now = crate::node::roster_book::now_ms();
    let Some(mark) = crate::node::phrase_restore::current(&store, &c.device.peer_id(), now) else { return Ok(None) };
    let no_wait = chosen_no_wait(&c);
    Ok(Some(WelcomeRestoreState { at_ms: mark.at_ms, branch: mark.branch.as_str().to_string(), empty: mark.empty, no_wait }))
}

struct Ctx {
    master: NativeKeypair,
    device: NativeKeypair,
    db_path: String,
    db_passphrase: String,
}

/// Never creates an identity: Home asks for the roster while Welcome is still up,
/// and a key minted then would skip Welcome on a fresh install.
fn ctx() -> Result<Ctx, String> {
    let id = crate::identity::load_existing_identity()?.ok_or("There is no identity on this device yet.")?;
    let db_path = crate::identity::data_dir()?
        .join("messages.db")
        .to_str()
        .ok_or("Invalid path encoding")?
        .to_string();
    Ok(Ctx {
        db_passphrase: super::storage::derive_db_key_public()?,
        master: id.keypair,
        device: id.device_keypair,
        db_path,
    })
}

/// What our own roster says about every device, this one first.
#[frb]
pub fn roster_status() -> Result<RosterStatus, String> {
    let c = ctx()?;
    let store = MessageStore::open(&c.db_path, &c.db_passphrase)?;
    let me = c.device.peer_id();
    let Some(roster) = crate::node::roster_book::load(&store, &c.master.peer_id()) else {
        return Ok(RosterStatus {
            member: false,
            protected: false,
            backup_wait: true,
            joins_at_ms: None,
            removed_by: None,
            wipe_at_ms: None,
            devices: Vec::new(),
            too_early: None,
            too_early_lost_since_ms: None,
            dropped_by_recovery_at_ms: None,
        });
    };
    let state = crate::node::roster_book::fold(&store, &roster);
    let seen = store.load_roster_seen(&roster.master, &roster.base()).unwrap_or_default();
    let mut devices: Vec<RosterDevice> = Vec::new();
    let mut push = |d: &String, kind: &str| {
        devices.push(RosterDevice {
            device_peer_id: d.clone(),
            state: kind.to_string(),
            this_device: *d == me,
            first_seen_ms: seen.get(d).copied(),
            added: if kind == "member" { roster.vouched_members_of(d, &state) } else { Vec::new() },
        });
    };
    for d in &state.members {
        push(d, "member");
    }
    for d in &state.pending {
        push(d, "pending");
    }
    for d in state.removed.keys() {
        push(d, "removed");
    }
    devices.sort_by_key(|d| !d.this_device);
    let removal = crate::node::roster_book::own_removal(&store);
    let outdated = crate::node::roster_book::own_phrase_outdated(&store, &roster, &state, &me);
    let too_early_lost_since_ms = outdated
        .as_ref()
        .filter(|o| o.kind == crate::node::roster_book::PhraseKind::Recover)
        .and_then(|o| crate::node::roster_book::recovery_lost_since(&store, &o.base));
    let dropped_by_recovery_at_ms = crate::node::roster_book::dropped_by_recovery_at(&store, &roster, &state, &me);
    Ok(RosterStatus {
        member: state.is_member(&me),
        protected: state.protected,
        backup_wait: !state.no_wait,
        joins_at_ms: (state.pending.contains(&me) && !state.no_wait)
            .then(|| seen.get(&me).map(|s| s + crate::identity::roster::PENDING_MATURITY_MS))
            .flatten(),
        removed_by: state.removed.get(&me).cloned().or_else(|| removal.as_ref().map(|r| r.0.clone())),
        wipe_at_ms: state
            .removed
            .contains_key(&me)
            .then(|| removal.map(|(_, at)| at.saturating_add(REMOVAL_GRACE_MS)))
            .flatten(),
        devices,
        too_early: outdated.map(|o| match o.kind {
            crate::node::roster_book::PhraseKind::Admit => "admit".to_string(),
            crate::node::roster_book::PhraseKind::Recover => "recover".to_string(),
        }),
        too_early_lost_since_ms,
        dropped_by_recovery_at_ms,
    })
}

/// Devices `f` stopped counting (`roster_book::lost_by_own_change`): the node drops
/// their sessions and moves the join locks they could extend.
fn changed(c: &Ctx, f: impl FnOnce(&Ctx) -> Result<(), String>) -> Result<(), String> {
    let master = c.master.peer_id();
    let store = MessageStore::open(&c.db_path, &c.db_passphrase)?;
    let held = crate::node::authority_view::hold_own(&store, &master);
    // Settled by the node, or at its next start when it is not running or stops first.
    let change = crate::node::settle_owed::TypedChange::begin(&store, &master, &c.db_path, &c.db_passphrase);
    if let Err(e) = f(c) {
        change.abort(&store);
        if held {
            crate::node::authority_view::release_own(&store, &master);
        }
        return Err(e);
    }
    let newly_revoked = change.landed(&store, &master, &c.device.peer_id(), &c.db_path, &c.db_passphrase);
    erase_stored_phrase(&c.db_path, &c.db_passphrase);
    let dropped = !newly_revoked.is_empty();
    // A node not started yet reads the roster at its start; nothing is lost.
    let sent = super::network::send_node_command(NodeCommand::RosterChanged { newly_revoked }).is_ok();
    // With devices dropped, the node lets the hold go once it has read what it held.
    if held && !(dropped && sent) {
        crate::node::authority_view::release_own(&store, &master);
    }
    Ok(())
}

/// What a phrase restore signs (PHRASE_RESTORE_DESIGN 1.2 step 9).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RestoreSign {
    /// The phrase admits the minted device into whatever base is current.
    Admit,
    /// A recovery keeping only the minted device; devices dropped as lost since then.
    Recover { lost_since_ms: i64, no_wait: bool },
}

/// A phrase restore signs into the database through the same path the in-app phrase
/// changes take: stamped past every held statement (`phrase_time`, HOL-SEC-218), with
/// what a recovery over a kept database drops owed a settling (HOL-SEC-216).
pub(crate) fn sign_restore(
    master: &NativeKeypair,
    device: &NativeKeypair,
    recovery: &NativeKeypair,
    sign: RestoreSign,
    db_path: &str,
    db_passphrase: &str,
) -> Result<(), String> {
    let c = Ctx { master: master.clone(), device: device.clone(), db_path: db_path.to_string(), db_passphrase: db_passphrase.to_string() };
    changed(&c, |c| match sign {
        RestoreSign::Admit => {
            crate::node::roster_book::admit_by_phrase(&c.master, recovery, &c.device, &c.db_path, &c.db_passphrase).map(|_| ())
        }
        RestoreSign::Recover { lost_since_ms, no_wait } => crate::node::roster_book::recover(
            &c.master, recovery, &c.device, &[], no_wait, Some(lost_since_ms), &c.db_path, &c.db_passphrase,
        )
        .map(|_| ()),
    })
}

/// The phrase is never kept once it has been typed on 0.12.
fn erase_stored_phrase(db_path: &str, db_passphrase: &str) {
    if let Ok(store) = MessageStore::open(db_path, db_passphrase) {
        let _ = store.delete_setting("recovery_mnemonic");
    }
}

/// Type the phrase to make it the root of the identity: a recovery keeping this
/// device and `keep`. Every other device stops counting at once, treated as lost or
/// stolen since `lost_since_ms` (DEVICE_PROOF_DESIGN 8.1).
#[frb]
pub fn recover_with_phrase(phrase: String, keep: Vec<String>, lost_since_ms: i64) -> Result<(), String> {
    let c = ctx()?;
    let (master, recovery) = crate::identity::recovery::recovery_key_for(&c.master.peer_id(), &phrase)?;
    let no_wait = chosen_no_wait(&c);
    changed(&c, |c| {
        crate::node::roster_book::recover(&master, &recovery, &c.device, &keep, no_wait, Some(lost_since_ms), &c.db_path, &c.db_passphrase)
            .map(|_| ())
    })
}

/// Whether a restored backup needs approval, as the person last chose it: a recovery of
/// ours that a later base outdated keeps its own choice (signed again with it), else
/// the held base decides.
fn chosen_no_wait(c: &Ctx) -> bool {
    let Ok(store) = MessageStore::open(&c.db_path, &c.db_passphrase) else { return false };
    let Some(roster) = crate::node::roster_book::load(&store, &c.master.peer_id()) else { return false };
    let state = crate::node::roster_book::fold(&store, &roster);
    match crate::node::roster_book::own_phrase_outdated(&store, &roster, &state, &c.device.peer_id()) {
        Some(own) if own.kind == crate::node::roster_book::PhraseKind::Recover => own.no_wait,
        _ => state.no_wait,
    }
}

/// The other devices a recovery keeps unless unticked, for devices last had at
/// `lost_since_ms`: only those this device counted before then.
#[frb]
pub fn recovery_kept_by_default(lost_since_ms: i64) -> Result<Vec<String>, String> {
    let c = ctx()?;
    let store = MessageStore::open(&c.db_path, &c.db_passphrase)?;
    let master = c.master.peer_id();
    let (_, state) =
        crate::node::roster_book::own(&master, &c.db_path, &c.db_passphrase).ok_or("Your devices could not be read.")?;
    Ok(crate::node::roster_book::recovery_kept_by_default(&store, &master, &state, &c.device.peer_id(), lost_since_ms))
}

/// Type the phrase to choose whether a device restored from a backup may join by
/// nobody refusing it for seven days. Signs a recovery that keeps every current
/// device, so devices still waiting to join ask again.
#[frb]
pub fn set_backup_wait(phrase: String, allowed: bool) -> Result<(), String> {
    let c = ctx()?;
    let (master, recovery) = crate::identity::recovery::recovery_key_for(&c.master.peer_id(), &phrase)?;
    let (_, state) = crate::node::roster_book::own(&c.master.peer_id(), &c.db_path, &c.db_passphrase)
        .ok_or("Your devices could not be read.")?;
    if !state.is_member(&c.device.peer_id()) {
        return Err("Only a device that belongs to your identity can change this.".into());
    }
    let keep: Vec<String> = state.members.into_iter().collect();
    changed(&c, |c| {
        crate::node::roster_book::recover(&master, &recovery, &c.device, &keep, !allowed, None, &c.db_path, &c.db_passphrase)
            .map(|_| ())
    })
}

/// Type the phrase on a device waiting to join: it joins at once, and nothing else
/// changes.
#[frb]
pub fn join_with_phrase(phrase: String) -> Result<(), String> {
    let c = ctx()?;
    let (master, recovery) = crate::identity::recovery::recovery_key_for(&c.master.peer_id(), &phrase)?;
    changed(&c, |c| {
        crate::node::roster_book::admit_by_phrase(&master, &recovery, &c.device, &c.db_path, &c.db_passphrase)
            .map(|_| ())
    })
}

/// Whether `phrase` is this identity's recovery phrase. Checks only; signs nothing.
#[frb]
pub fn check_recovery_phrase(phrase: String) -> Result<bool, String> {
    let c = ctx()?;
    Ok(crate::identity::recovery::recovery_key_for(&c.master.peer_id(), &phrase).is_ok())
}

/// The phrase an identity from before 0.12 kept in its database, shown one last time
/// at the upgrade and erased once confirmed. `None` once it is gone.
#[frb]
pub fn stored_phrase_for_upgrade() -> Result<Option<String>, String> {
    let c = ctx()?;
    let store = MessageStore::open(&c.db_path, &c.db_passphrase)?;
    Ok(store.load_setting("recovery_mnemonic")?.filter(|p| !p.trim().is_empty()))
}

/// The one-time confirmation of the phrase an identity from before 0.12 stored. Where
/// the phrase already roots the roster (the first 0.12 start signed with it), the
/// stored copy is only erased: a recovery signed now would supersede the upgrade's and
/// drop every device vouched since. Otherwise it signs a recovery keeping every member.
#[frb]
pub fn confirm_stored_phrase(phrase: String) -> Result<(), String> {
    let c = ctx()?;
    let (master, recovery) = crate::identity::recovery::recovery_key_for(&c.master.peer_id(), &phrase)?;
    if crate::node::roster_book::rooted_by(&master, &c.device, &recovery, &c.db_path, &c.db_passphrase)? {
        erase_stored_phrase(&c.db_path, &c.db_passphrase);
        return Ok(());
    }
    let (keep, no_wait) = crate::node::roster_book::own(&c.master.peer_id(), &c.db_path, &c.db_passphrase)
        .map(|(_, s)| (s.members.into_iter().collect::<Vec<_>>(), s.no_wait))
        .unwrap_or_default();
    changed(&c, |c| {
        crate::node::roster_book::recover(&master, &recovery, &c.device, &keep, no_wait, None, &c.db_path, &c.db_passphrase)
            .map(|_| ())
    })
}

/// The phrase this identity stored before 0.12, while it is still here.
pub(crate) fn stored_phrase() -> Option<zeroize::Zeroizing<String>> {
    let c = ctx().ok()?;
    let store = MessageStore::open(&c.db_path, &c.db_passphrase).ok()?;
    let phrase = zeroize::Zeroizing::new(store.load_setting("recovery_mnemonic").ok().flatten()?);
    crate::identity::recovery::recovery_key_for(&c.master.peer_id(), &phrase).ok()?;
    Some(phrase)
}

/// What removing a device takes with it, for the remove dialog.
pub struct DeviceRemovalPlan {
    /// Devices it linked after the chosen time: removed with it, no choice.
    pub forced: Vec<String>,
    /// The other devices only it linked: removed too while the toggle stays on.
    pub optional: Vec<String>,
    /// Where that toggle starts: on for lost or stolen, off for retiring.
    pub optional_on: bool,
    /// False when a device closer to the recovery phrase removed this one first: the
    /// removal then does not take effect for servers until the phrase is used.
    pub takes_effect_for_servers: bool,
}

/// The plan for removing `device_peer_id`: retiring when `lost_since_ms` is None, else
/// lost or stolen since then.
#[frb]
pub fn remove_device_plan(device_peer_id: String, lost_since_ms: Option<i64>) -> Result<DeviceRemovalPlan, String> {
    let c = ctx()?;
    let store = MessageStore::open(&c.db_path, &c.db_passphrase)?;
    let roster = crate::node::roster_book::load(&store, &c.master.peer_id()).ok_or("There is no roster on this device yet.")?;
    let mode = crate::node::roster_book::RemoveMode::from_lost_since(lost_since_ms);
    let me = c.device.peer_id();
    let plan = crate::node::roster_book::removal_plan(&store, &roster, &me, &device_peer_id, mode);
    Ok(DeviceRemovalPlan {
        forced: plan.forced,
        optional: plan.optional,
        optional_on: plan.optional_on,
        takes_effect_for_servers: crate::node::roster_book::removal_takes_effect(&roster, &c.device, &device_peer_id),
    })
}

/// This device vouches for a device waiting to join.
#[frb]
pub fn approve_device(device_peer_id: String) -> Result<(), String> {
    super::network::send_node_command(NodeCommand::ApproveDevice { device_peer_id })
}

/// This device refuses a device waiting to join.
#[frb]
pub fn refuse_device(device_peer_id: String) -> Result<(), String> {
    super::network::send_node_command(NodeCommand::RevokeDevice {
        device_peer_id,
        mode: crate::node::roster_book::RemoveMode::Retire,
        with_dependents: false,
    })
}

/// The phrase signs a destruction order for every device of the identity. Without a
/// phrase only an identity whose phrase was never typed on 0.12 can issue one.
pub(crate) fn destroy_order(
    phrase: Option<&str>,
    notify_friends: bool,
) -> Result<crate::node::DestroyIdentity, String> {
    let c = ctx()?;
    let recovery = match phrase {
        Some(p) => Some(crate::identity::recovery::recovery_key_for(&c.master.peer_id(), p)?.1),
        None => {
            let protected = crate::node::roster_book::own(&c.master.peer_id(), &c.db_path, &c.db_passphrase)
                .is_some_and(|(_, s)| s.protected);
            if protected {
                return Err("Type your recovery phrase to erase your identity everywhere.".into());
            }
            None
        }
    };
    Ok(crate::node::crypto_handler::build_destroy_identity(
        &c.master,
        recovery.as_ref(),
        crate::node::roster_book::now_ms(),
        Vec::new(),
        notify_friends,
    ))
}

/// The phrase's permission for THIS device to order the identity destroyed, kept in
/// the duress slot for the "everywhere" scope.
pub(crate) fn destroy_permission(phrase: &str) -> Result<crate::identity::duress::DestroyPermission, String> {
    let c = ctx()?;
    let (master, recovery) = crate::identity::recovery::recovery_key_for(&c.master.peer_id(), phrase)?;
    let at_ms = crate::node::roster_book::now_ms();
    let d = crate::node::crypto_handler::sign_destroy_delegation(&master, &recovery, &c.device.peer_id(), at_ms);
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD;
    let r_pub: [u8; 32] = b64
        .decode(&d.r_pub)
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or("Bad recovery key")?;
    let sig_r: [u8; 64] = b64
        .decode(&d.sig_r)
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or("Bad signature")?;
    Ok(crate::identity::duress::DestroyPermission { at_ms, r_pub, sig_r })
}

/// The delegation a duress code carries, rebuilt for this device.
pub(crate) fn delegation_from(
    perm: &crate::identity::duress::DestroyPermission,
) -> Option<crate::node::DestroyDelegation> {
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD;
    let device = crate::identity::load_existing_identity().ok()??.device_keypair.peer_id();
    Some(crate::node::DestroyDelegation {
        device,
        at_ms: perm.at_ms,
        r_pub: b64.encode(perm.r_pub),
        sig_r: b64.encode(perm.sig_r),
        device_sig: String::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Home asks for the roster while Welcome is still on screen: on a fresh install
    /// that must fail and leave the data root empty, or Welcome never appears.
    #[test]
    fn a_roster_read_never_mints_an_identity() {
        let _g = crate::node::resolver::test_lock();
        let _s = crate::api::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();

        assert!(roster_status().is_err());
        assert!(stored_phrase_for_upgrade().is_err());
        assert!(!tmp.path().join("identity.key").exists(), "no key was minted");
        assert!(!tmp.path().join("identity.device").exists(), "no device key was minted");
    }

    const PHRASE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    /// An identity from before 0.12 on disk: `PHRASE`'s master, a device key, a database
    /// holding the stored phrase and, when given, a 0.11 list naming those devices.
    fn legacy_identity_on_disk(dir: &std::path::Path, list: Option<&[String]>) -> Ctx {
        let (master, _) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        let device = NativeKeypair::from_secret_bytes(&[0x5b; 32]);
        for (name, kp) in [("identity.key", &master), ("identity.device", &device)] {
            std::fs::write(dir.join(name), kp.to_protobuf_encoding().unwrap()).unwrap();
        }
        let c = ctx().unwrap();
        MessageStore::migrate_auto_vacuum_once(&c.db_path, &c.db_passphrase).unwrap();
        let store = MessageStore::open(&c.db_path, &c.db_passphrase).unwrap();
        store.save_setting("recovery_mnemonic", PHRASE).unwrap();
        if let Some(devices) = list {
            let old = crate::node::crypto_handler::build_signed_device_list(&master, 2, devices.to_vec(), Vec::new());
            let json = serde_json::to_string(&old).unwrap();
            store.save_device_list(&master.peer_id(), &json, old.version, &old.devices, 0).unwrap();
        }
        c
    }

    /// Decision C. Once the first 0.12 start signed the upgrade with the stored phrase,
    /// confirming that phrase signs nothing (a recovery dated now would drop every
    /// device vouched since) and only erases the stored copy, which the start kept.
    #[test]
    fn confirming_the_stored_phrase_after_the_upgrade_only_erases_it() {
        let _g = crate::node::resolver::test_lock();
        let _s = crate::api::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let c = legacy_identity_on_disk(tmp.path(), None);
        let store = MessageStore::open(&c.db_path, &c.db_passphrase).unwrap();
        let (upgraded, state) = crate::node::roster_book::ensure_own(&store, &c.master, &c.device, &c.db_path);
        drop(store);
        assert!(state.protected, "the first start signed no recovery");
        assert_eq!(stored_phrase_for_upgrade().unwrap().as_deref(), Some(PHRASE), "the start erased the stored phrase");

        confirm_stored_phrase(PHRASE.into()).unwrap();
        let (held, _) = crate::node::roster_book::own(&c.master.peer_id(), &c.db_path, &c.db_passphrase).unwrap();
        assert_eq!(held, upgraded, "the confirmation signed a new recovery");
        assert_eq!(stored_phrase_for_upgrade().unwrap(), None, "the confirmation kept the stored phrase");
    }

    /// An identity on disk from `PHRASE` with no stored phrase and an empty database.
    fn fresh_identity_on_disk(dir: &std::path::Path) -> Ctx {
        let (master, _) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        let device = NativeKeypair::from_secret_bytes(&[0x5b; 32]);
        for (name, kp) in [("identity.key", &master), ("identity.device", &device)] {
            std::fs::write(dir.join(name), kp.to_protobuf_encoding().unwrap()).unwrap();
        }
        ctx().unwrap()
    }

    /// A recovery signed elsewhere, dated `at`, keeping only another device.
    fn recovery_elsewhere(c: &Ctx, at: i64) {
        let (master, recovery) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        let other = NativeKeypair::from_secret_bytes(&[0x5f; 32]);
        let store = MessageStore::open(&c.db_path, &c.db_passphrase).unwrap();
        let mut r = crate::node::roster_book::load(&store, &master.peer_id()).unwrap();
        r.add_consent(crate::identity::roster::sign_consent(&other, &master.peer_id()));
        let rec = crate::identity::roster::sign_recovery(&master, &recovery, at, &[other.peer_id()], false);
        r.add_phrase_statement(&crate::identity::roster::r_pub_of(&recovery), Some(rec), None).unwrap();
        crate::node::roster_book::merge_for_test(&store, &r, &master.peer_id(), &c.device.peer_id());
    }

    /// HOL-SEC-218: our phrase admission, then a base dated after it (a clock behind, or
    /// a change made elsewhere): the lock asks for the phrase again, not "restored from
    /// a backup".
    #[test]
    fn roster_status_says_too_early_for_an_admission_the_base_outdated() {
        let _g = crate::node::resolver::test_lock();
        let _s = crate::api::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let c = fresh_identity_on_disk(tmp.path());
        join_with_phrase(PHRASE.into()).unwrap();
        assert!(roster_status().unwrap().member, "precondition: the phrase admitted this device");
        recovery_elsewhere(&c, crate::node::roster_book::now_ms() + 5 * 60 * 1000);

        let status = roster_status().unwrap();

        assert!(!status.member);
        assert_eq!(status.too_early.as_deref(), Some("admit"));
        assert_eq!(status.dropped_by_recovery_at_ms, None, "too early wins over left out");
        join_with_phrase(PHRASE.into()).unwrap();
        assert!(roster_status().unwrap().member, "typing the phrase again dates it past the base");
    }

    /// Review (Dart half, b): our recovery said "backups need approval"; a base dated
    /// after it says otherwise. Typing the phrase again keeps the person's choice, and the
    /// Home card reports it, before and after.
    #[test]
    fn a_too_early_recovery_keeps_the_first_recoverys_no_wait() {
        let _g = crate::node::resolver::test_lock();
        let _s = crate::api::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let c = fresh_identity_on_disk(tmp.path());
        let (master, recovery) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        sign_restore(&master, &c.device, &recovery, RestoreSign::Recover { lost_since_ms: 1_000, no_wait: true }, &c.db_path, &c.db_passphrase).unwrap();
        let mark = crate::node::phrase_restore::Mark {
            at_ms: crate::node::roster_book::now_ms(),
            branch: crate::node::phrase_restore::Branch::Recover,
            empty: true,
            device: c.device.peer_id(),
        };
        crate::node::phrase_restore::write(&MessageStore::open(&c.db_path, &c.db_passphrase).unwrap(), &mark).unwrap();
        recovery_elsewhere(&c, crate::node::roster_book::now_ms() + 5 * 60 * 1000);
        let status = roster_status().unwrap();
        assert_eq!(status.too_early.as_deref(), Some("recover"));
        assert_eq!(status.too_early_lost_since_ms, Some(1_000));
        assert!(welcome_restore_state().unwrap().unwrap().no_wait, "the card reports the outdated base's choice");

        recover_with_phrase(PHRASE.into(), Vec::new(), status.too_early_lost_since_ms.unwrap()).unwrap();

        let status = roster_status().unwrap();
        assert!(status.member);
        assert!(!status.backup_wait, "typing the phrase again let restored backups wait in");
        assert!(welcome_restore_state().unwrap().unwrap().no_wait);
    }

    /// Review (Dart half, finding 1): a recovery's T lands before its base does, so no
    /// crash between the two writes leaves a recovery whose T is unknown.
    #[test]
    fn a_recovery_records_its_t_before_its_roster() {
        let _g = crate::node::resolver::test_lock();
        let _s = crate::api::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let c = fresh_identity_on_disk(tmp.path());
        let (master, recovery) = crate::identity::recovery::keys_from_phrase(PHRASE).unwrap();
        // The roster save is refused (a crash right before it): the T is there already.
        crate::node::authority_view::refuse_book_for_test(&c.device.peer_id(), &master.peer_id());
        let signed = crate::node::roster_book::recover(&master, &recovery, &c.device, &[], true, Some(7_000), &c.db_path, &c.db_passphrase);
        crate::node::authority_view::unrefuse_book_for_test(&c.device.peer_id());
        let (roster, _) = signed.unwrap();
        let store = MessageStore::open(&c.db_path, &c.db_passphrase).unwrap();
        assert!(crate::node::roster_book::load(&store, &master.peer_id()).is_none(), "precondition: the roster never landed");
        assert_eq!(crate::node::roster_book::recovery_lost_since(&store, &roster.base()), Some(7_000));
    }

    /// D3b: a device that counted, left out by a recovery typed on another device.
    #[test]
    fn roster_status_says_dropped_by_recovery_for_a_device_the_base_left_out() {
        let _g = crate::node::resolver::test_lock();
        let _s = crate::api::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let c = fresh_identity_on_disk(tmp.path());
        {
            let store = MessageStore::open(&c.db_path, &c.db_passphrase).unwrap();
            let (_, state) = crate::node::roster_book::ensure_own(&store, &c.master, &c.device, &c.db_path);
            assert!(state.is_member(&c.device.peer_id()), "precondition: this device counts");
        }
        let at = crate::node::roster_book::now_ms() - 1_000;
        recovery_elsewhere(&c, at);

        let status = roster_status().unwrap();

        assert!(!status.member);
        assert_eq!(status.too_early, None);
        assert_eq!(status.dropped_by_recovery_at_ms, Some(at));
    }

    /// C-IDENTITY-09. The Devices page learns what removing a device keeps: the
    /// members it added, and nothing for a device that added none.
    #[test]
    fn the_roster_status_names_what_a_removal_keeps() {
        use crate::identity::roster::{sign_consent, sign_vouch};
        let _g = crate::node::resolver::test_lock();
        let _s = crate::api::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let c = legacy_identity_on_disk(tmp.path(), None);
        let store = MessageStore::open(&c.db_path, &c.db_passphrase).unwrap();
        let (mut roster, _) = crate::node::roster_book::ensure_own(&store, &c.master, &c.device, &c.db_path);
        let own = c.master.peer_id();
        let (laptop, phone) = (NativeKeypair::from_secret_bytes(&[0x5d; 32]), NativeKeypair::from_secret_bytes(&[0x5e; 32]));
        let base = roster.base();
        roster.add_vouch(sign_vouch(&c.device, &own, &base, &laptop.peer_id()));
        roster.add_vouch(sign_vouch(&laptop, &own, &base, &phone.peer_id()));
        roster.add_consent(sign_consent(&laptop, &own));
        roster.add_consent(sign_consent(&phone, &own));
        crate::node::roster_book::merge_for_test(&store, &roster, &own, &c.device.peer_id());
        drop(store);

        let status = roster_status().unwrap();
        let added = |d: &NativeKeypair| {
            status.devices.iter().find(|x| x.device_peer_id == d.peer_id()).map(|x| x.added.clone()).unwrap_or_default()
        };
        assert_eq!(added(&laptop), vec![phone.peer_id()]);
        assert_eq!(added(&c.device), vec![laptop.peer_id()]);
        assert!(added(&phone).is_empty());
    }

    /// A device its 0.11 list does not name signed nothing at start: confirming the
    /// stored phrase there roots the identity, keeping this device.
    #[test]
    fn confirming_the_stored_phrase_signs_where_the_start_did_not() {
        let _g = crate::node::resolver::test_lock();
        let _s = crate::api::storage::store_test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();
        let other = NativeKeypair::from_secret_bytes(&[0x5c; 32]).peer_id();
        let c = legacy_identity_on_disk(tmp.path(), Some(std::slice::from_ref(&other)));
        let store = MessageStore::open(&c.db_path, &c.db_passphrase).unwrap();
        let (_, state) = crate::node::roster_book::ensure_own(&store, &c.master, &c.device, &c.db_path);
        drop(store);
        assert!(!state.protected && state.pending.contains(&c.device.peer_id()));

        confirm_stored_phrase(PHRASE.into()).unwrap();
        let (_, state) = crate::node::roster_book::own(&c.master.peer_id(), &c.db_path, &c.db_passphrase).unwrap();
        assert!(state.protected && state.is_member(&c.device.peer_id()), "{state:?}");
        assert_eq!(stored_phrase_for_upgrade().unwrap(), None);
    }
}
