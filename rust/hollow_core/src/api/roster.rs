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
}

/// What our own roster says, for the Devices page and the lock screens.
pub struct RosterStatus {
    /// This device belongs to the identity.
    pub member: bool,
    /// The recovery phrase is the root (a recovery exists).
    pub protected: bool,
    /// This device asked to join and waits: when it becomes a member without anyone
    /// answering, on this device's clock.
    pub joins_at_ms: Option<i64>,
    /// This device was removed: by whom, and when it erases itself.
    pub removed_by: Option<String>,
    pub wipe_at_ms: Option<i64>,
    pub devices: Vec<RosterDevice>,
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
            joins_at_ms: None,
            removed_by: None,
            wipe_at_ms: None,
            devices: Vec::new(),
        });
    };
    let state = crate::node::roster_book::fold(&store, &roster);
    let seen = store.load_roster_seen(&roster.master).unwrap_or_default();
    let mut devices: Vec<RosterDevice> = Vec::new();
    let mut push = |d: &String, kind: &str| {
        devices.push(RosterDevice {
            device_peer_id: d.clone(),
            state: kind.to_string(),
            this_device: *d == me,
            first_seen_ms: seen.get(d).copied(),
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
    Ok(RosterStatus {
        member: state.is_member(&me),
        protected: state.protected,
        joins_at_ms: state
            .pending
            .contains(&me)
            .then(|| seen.get(&me).map(|s| s + crate::identity::roster::PENDING_MATURITY_MS))
            .flatten(),
        removed_by: state.removed.get(&me).cloned().or_else(|| removal.as_ref().map(|r| r.0.clone())),
        wipe_at_ms: state
            .removed
            .contains_key(&me)
            .then(|| removal.map(|(_, at)| at.saturating_add(REMOVAL_GRACE_MS)))
            .flatten(),
        devices,
    })
}

/// Members before `f` that are not members after it: the node drops their sessions.
fn changed(c: &Ctx, f: impl FnOnce(&Ctx) -> Result<(), String>) -> Result<(), String> {
    let before = crate::node::roster_book::own(&c.master.peer_id(), &c.db_path, &c.db_passphrase)
        .map(|(_, s)| s.members)
        .unwrap_or_default();
    f(c)?;
    let after = crate::node::roster_book::own(&c.master.peer_id(), &c.db_path, &c.db_passphrase)
        .map(|(_, s)| s.members)
        .unwrap_or_default();
    let newly_revoked: Vec<String> = before.difference(&after).cloned().collect();
    erase_stored_phrase(&c.db_path, &c.db_passphrase);
    // A node not started yet reads the roster at its start; nothing is lost.
    let _ = super::network::send_node_command(NodeCommand::RosterChanged { newly_revoked });
    Ok(())
}

/// The phrase is never kept once it has been typed on 0.12.
fn erase_stored_phrase(db_path: &str, db_passphrase: &str) {
    if let Ok(store) = MessageStore::open(db_path, db_passphrase) {
        let _ = store.delete_setting("recovery_mnemonic");
    }
}

/// Type the phrase to make it the root of the identity: a recovery keeping this
/// device and `keep`. Every other device stops counting at once. Also the one-time
/// confirmation of an identity from before 0.12, which erases the stored phrase.
#[frb]
pub fn recover_with_phrase(phrase: String, keep: Vec<String>) -> Result<(), String> {
    let c = ctx()?;
    let (master, recovery) = crate::identity::recovery::recovery_key_for(&c.master.peer_id(), &phrase)?;
    changed(&c, |c| {
        crate::node::roster_book::recover(&master, &recovery, &c.device, &keep, &c.db_path, &c.db_passphrase)
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

/// This device vouches for a device waiting to join.
#[frb]
pub fn approve_device(device_peer_id: String) -> Result<(), String> {
    super::network::send_node_command(NodeCommand::ApproveDevice { device_peer_id })
}

/// This device refuses a device waiting to join.
#[frb]
pub fn refuse_device(device_peer_id: String) -> Result<(), String> {
    super::network::send_node_command(NodeCommand::RevokeDevice { device_peer_id })
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
        let tmp = tempfile::tempdir().unwrap();
        // SAFETY: serialized by the locks above.
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()) };
        crate::identity::encryption::clear_session_key();

        assert!(roster_status().is_err());
        assert!(stored_phrase_for_upgrade().is_err());
        assert!(!tmp.path().join("identity.key").exists(), "no key was minted");
        assert!(!tmp.path().join("identity.device").exists(), "no device key was minted");
    }
}
