use super::*;
use crate::identity::native_identity::NativeKeypair;
use crate::identity::platform_keystore::test_support::*;
use crate::identity::platform_keystore::{key_that_opens, login_keys, settle_move_judged, Moved, Step, Store};

const K1: [u8; 32] = [0x11; 32];

fn plain(seed: u8) -> Vec<u8> {
    NativeKeypair::from_secret_bytes(&[seed; 32]).to_protobuf_encoding().unwrap()
}

fn seal(plain: &[u8], key: &[u8; 32]) -> Vec<u8> {
    encryption::encrypt_identity(plain, key, &[0u8; 16], false, true).unwrap()
}

/// A keychain-only identity (0.13's default) under `key`, its key in the login
/// keychain the way 0.13 wrote it, and a login keychain that lets only the item's
/// maker delete it (the field case).
struct Fx {
    tmp: crate::test_tmp::TestDir,
    /// Held by a password fixture: the Argon2id count other tests read is process-wide.
    _derives: Option<std::sync::MutexGuard<'static, ()>>,
}

impl Fx {
    fn new(key: &[u8; 32]) -> Self {
        use_mac_layout(Some(true));
        reset_fakes();
        let fx = Self { tmp: crate::test_tmp::tempdir().unwrap(), _derives: None };
        fx.lay_down(key, 0x41);
        old_build_writes(&fx.slot(), key);
        inject(Fault::LegacyNotOwner);
        fx
    }

    fn dir(&self) -> &Path {
        self.tmp.path()
    }

    fn slot(&self) -> String {
        profile_slot_name(self.dir())
    }

    /// What a phrase restore in an old build does: new files under `key`.
    fn lay_down(&self, key: &[u8; 32], seed: u8) {
        std::fs::write(self.dir().join(KEY_FILE), seal(&plain(seed), key)).unwrap();
        std::fs::write(self.dir().join(DEVICE_FILE), seal(&plain(seed + 1), key)).unwrap();
    }

    fn file(&self, name: &str) -> Vec<u8> {
        std::fs::read(self.dir().join(name)).unwrap()
    }

    /// One app start: the move, then the re-key.
    fn start(&self) -> (Moved, Rekey) {
        let ours = Ours::of(&[self.dir().to_path_buf()]);
        let moved = settle_move_judged(self.dir(), &|k| ours.opened_by(k));
        (moved, settle(self.dir()))
    }

    /// Some stored key opens each file, without changing anything.
    fn both_open_somehow(&self) -> bool {
        key_that_opens(self.dir(), &self.file(KEY_FILE)).is_some()
            && key_that_opens(self.dir(), &self.file(DEVICE_FILE)).is_some()
    }

    /// What the launch unlock does: the key that opens `identity.key`, the device
    /// file healed onto it, and both opening to the identity laid down with `seed`.
    fn unlocks(&self, seed: u8) -> bool {
        let Some((_, key)) = key_that_opens(self.dir(), &self.file(KEY_FILE)) else { return false };
        heal_device_file(self.dir(), &key, true);
        encryption::decrypt_identity(&self.file(KEY_FILE), &key).ok() == Some(plain(seed))
            && encryption::decrypt_identity(&self.file(DEVICE_FILE), &key).ok() == Some(plain(seed + 1))
    }

    /// The goal: the key no longer opens either file, the profile slot opens both,
    /// and no staged key is left.
    fn inert(&self, key: &[u8; 32], seed: u8) -> Result<(), String> {
        for name in [KEY_FILE, DEVICE_FILE] {
            if opens(&self.file(name), key) {
                return Err(format!("the old key still opens {name}"));
            }
        }
        let profile = profile_value(self.dir()).ok_or("no profile slot")?;
        let profile = <[u8; 32]>::try_from(profile.as_slice()).map_err(|_| "short")?;
        if encryption::decrypt_identity(&self.file(KEY_FILE), &profile).ok() != Some(plain(seed))
            || encryption::decrypt_identity(&self.file(DEVICE_FILE), &profile).ok() != Some(plain(seed + 1))
        {
            return Err("the profile slot does not open both files to the same identity".into());
        }
        if names_in(Store::Keys).iter().any(|n| n.ends_with(".rekey")) {
            return Err(format!("a staged key stayed: {:?}", names_in(Store::Keys)));
        }
        Ok(())
    }
}

impl Drop for Fx {
    fn drop(&mut self) {
        clear_faults();
        clear_hook();
        encryption::test_faults::clear();
    }
}

/// Field report (signed 0.14, macOS 26): the login item 0.13 made cannot be deleted
/// by 0.14, so after the first start its key must open nothing, and the second start
/// writes and says nothing.
#[test]
fn a_login_item_only_its_maker_may_delete_opens_nothing_after_the_first_start() {
    let fx = Fx::new(&K1);
    let (moved, rekey) = fx.start();
    assert_eq!((moved.held, moved.wrote), (1, 1), "{moved:?}");
    assert_eq!(rekey, Rekey::Rekeyed { stay: 1 });
    assert_eq!(held(Store::Legacy, &fx.slot()), Some(K1.to_vec()), "the fake let the delete through");
    fx.inert(&K1, 0x41).unwrap();
    assert!(fx.unlocks(0x41));

    let _ = take_writes();
    let (moved, rekey) = fx.start();
    assert!(!moved.news(), "the second start had news: {moved:?}");
    assert_eq!(rekey, Rekey::Nothing);
    assert_eq!(take_writes(), 0, "the second start wrote the keychain");
    fx.inert(&K1, 0x41).unwrap();
}

/// A process killed after any step of the re-key still opens (with or without the
/// next start's settle first), and the next start finishes the job.
#[test]
fn a_rekey_killed_at_any_step_still_opens_and_finishes_at_the_next_start() {
    let steps = [Step::RekeyStaged, Step::RekeyKeyFile, Step::RekeyDeviceFile, Step::RekeyPromoted, Step::RekeyUnstaged];
    for die_at in steps {
        for unlock_first in [false, true] {
            let fx = Fx::new(&K1);
            set_hook(move |at, _| at != die_at);
            let (_, rekey) = fx.start();
            clear_hook();
            assert_eq!(rekey, Rekey::Died, "{die_at:?}: the hook never fired");
            assert!(fx.both_open_somehow(), "{die_at:?}: a file no stored key opens");
            if unlock_first {
                assert!(fx.unlocks(0x41), "{die_at:?}: the unlock after the kill failed");
            }
            let _ = fx.start();
            fx.inert(&K1, 0x41).map_err(|e| format!("{die_at:?}, unlock first {unlock_first}: {e}")).unwrap();
            assert!(fx.unlocks(0x41), "{die_at:?}: no unlock after the finish");
            let (moved, rekey) = fx.start();
            assert!(!moved.news() && rekey == Rekey::Nothing, "{die_at:?}: a third start found work: {moved:?} {rekey:?}");
        }
    }
}

/// A cut between the two files, then the person deletes the old login item: the
/// staged key opens one file and the profile slot the other, so neither may go
/// until the re-key promotes the new one.
#[test]
fn a_cut_rekey_survives_the_old_login_item_going() {
    for die_at in [Step::RekeyKeyFile, Step::RekeyDeviceFile] {
        let fx = Fx::new(&K1);
        set_hook(move |at, _| at != die_at);
        let _ = fx.start();
        clear_hook();
        fake_remove(Store::Legacy, &fx.slot());
        assert!(fx.unlocks(0x41), "{die_at:?}");
        let (_, rekey) = fx.start();
        assert_eq!(rekey, Rekey::Finished, "{die_at:?}");
        fx.inert(&K1, 0x41).unwrap();
    }
}

/// A full disk or a read-only folder stops the re-key with the files exactly as
/// they were, no staged key left, and a later start finishes it.
#[test]
fn a_file_that_will_not_write_stops_the_rekey_and_loses_nothing() {
    for file in [KEY_FILE, DEVICE_FILE] {
        let fx = Fx::new(&K1);
        let before = (fx.file(KEY_FILE), fx.file(DEVICE_FILE));
        encryption::test_faults::fail_rename_of(file);
        let (_, rekey) = fx.start();
        encryption::test_faults::clear();
        assert!(matches!(rekey, Rekey::Failed(_)), "{file}: {rekey:?}");
        assert_eq!((fx.file(KEY_FILE), fx.file(DEVICE_FILE)), before, "{file}: a file changed");
        assert!(names_in(Store::Keys).iter().all(|n| !n.ends_with(".rekey")), "{file}: a staged key stayed");
        assert!(fx.unlocks(0x41), "{file}");
        assert_eq!(fx.start().1, Rekey::Rekeyed { stay: 1 }, "{file}");
        fx.inert(&K1, 0x41).unwrap();
    }
}

/// A keychain that will not keep the staged key changes no file.
#[test]
fn a_staged_key_that_will_not_store_changes_nothing() {
    let fx = Fx::new(&K1);
    let before = (fx.file(KEY_FILE), fx.file(DEVICE_FILE));
    let ours = Ours::of(&[fx.dir().to_path_buf()]);
    let _ = settle_move_judged(fx.dir(), &|k| ours.opened_by(k));
    inject(Fault::StoreFails);
    assert!(matches!(settle(fx.dir()), Rekey::Failed(_)));
    assert_eq!((fx.file(KEY_FILE), fx.file(DEVICE_FILE)), before);
    assert!(fx.unlocks(0x41));
}

/// The person downgrades and restores the phrase in 0.13: new files, a new login
/// key. The next 0.14 start re-keys off that one too.
#[test]
fn a_downgrade_that_writes_a_new_login_key_is_rekeyed_again() {
    let fx = Fx::new(&K1);
    let _ = fx.start();
    let k1b = [0x12; 32];
    fx.lay_down(&k1b, 0x51);
    old_build_writes(&fx.slot(), &k1b);
    assert_eq!(fx.start().1, Rekey::Rekeyed { stay: 1 });
    fx.inert(&k1b, 0x51).unwrap();
    assert!(fx.unlocks(0x51));
}

/// One profile's start re-keys only its own files: another profile's login key
/// keeps opening that profile until it starts, and neither start rewrites the
/// other's keys afterwards.
#[test]
fn another_profiles_login_key_waits_for_that_profile() {
    let a = Fx::new(&K1);
    let b = Fx { tmp: crate::test_tmp::tempdir().unwrap(), _derives: None };
    let kb = [0x13; 32];
    b.lay_down(&kb, 0x61);
    old_build_writes(&b.slot(), &kb);
    let b_before = (b.file(KEY_FILE), b.file(DEVICE_FILE));
    let _ = a.start();
    assert_eq!((b.file(KEY_FILE), b.file(DEVICE_FILE)), b_before, "A's start rewrote B's files");
    assert!(b.unlocks(0x61));
    let (moved, _) = a.start();
    assert!(!moved.news(), "A's second start: {moved:?}");
    assert_eq!(b.start().1, Rekey::Rekeyed { stay: 1 });
    b.inert(&kb, 0x61).unwrap();
    let _ = take_writes();
    let (moved, _) = a.start();
    assert!(!moved.news() && take_writes() == 0, "A's start after B re-keyed: {moved:?}");
    b.inert(&kb, 0x61).unwrap();
}

/// A key staged by a start that died before any file changed, once no login key
/// opens the files any more, is dropped, never left to outlive them.
#[test]
fn a_staged_key_no_file_needs_is_dropped() {
    let fx = Fx::new(&K1);
    set_hook(|at, _| at != Step::RekeyStaged);
    let _ = fx.start();
    clear_hook();
    assert!(names_in(Store::Keys).iter().any(|n| n.ends_with(".rekey")));
    fake_remove(Store::Legacy, &fx.slot());
    assert_eq!(settle(fx.dir()), Rekey::Nothing);
    assert!(names_in(Store::Keys).iter().all(|n| !n.ends_with(".rekey")), "{:?}", names_in(Store::Keys));
    assert!(fx.unlocks(0x41));
}

/// Password identities are the password's: `0x01` keeps nothing in the keychain,
/// and a `0x03` cached key changes only with the password. Neither file changes.
#[test]
fn a_password_identity_is_never_rekeyed() {
    use_mac_layout(Some(true));
    let tmp = crate::test_tmp::tempdir().unwrap();
    let key = [0x14; 32];
    for (flags, answer) in [(0x01, Rekey::Nothing), (0x03, Rekey::PasswordKey)] {
        let sealed = encryption::encrypt_with_flags(&plain(0x71), &key, &[0x23; 16], flags).unwrap();
        std::fs::write(tmp.path().join(KEY_FILE), &sealed).unwrap();
        old_build_writes(&profile_slot_name(tmp.path()), &key);
        assert_eq!(settle(tmp.path()), answer, "flags {flags:#x}");
        assert_eq!(std::fs::read(tmp.path().join(KEY_FILE)).unwrap(), sealed, "flags {flags:#x}: the file changed");
        assert!(names_in(Store::Keys).is_empty(), "flags {flags:#x}: a key was staged");
    }
}

/// No login key opens the files: nothing is written.
#[test]
fn an_identity_no_login_key_opens_is_left_alone() {
    use_mac_layout(Some(true));
    let tmp = crate::test_tmp::tempdir().unwrap();
    std::fs::write(tmp.path().join(KEY_FILE), seal(&plain(0x41), &K1)).unwrap();
    set_profile(tmp.path(), &K1);
    old_build_writes(&profile_slot_name(tmp.path()), &[0x15; 32]);
    let _ = take_writes();
    assert_eq!(settle(tmp.path()), Rekey::Nothing);
    assert_eq!(take_writes(), 0);
    assert_eq!(profile_value(tmp.path()), Some(K1.to_vec()));
}

/// The re-key's old key leaves the protected keychain too: the profile slot of
/// another group and this root's conflict copies, never a key it does not hold.
#[test]
fn the_old_key_leaves_the_protected_keychain() {
    let fx = Fx::new(&K1);
    plant(Store::AppId, &fx.slot(), &K1);
    plant(Store::Keys, &format!("{}.m.{}", fx.slot(), "ab".repeat(8)), &K1);
    let other = [0x16; 32];
    plant(Store::Keys, &machine_slot_name(), &other);
    let _ = fx.start();
    fx.inert(&K1, 0x41).unwrap();
    assert_eq!(held(Store::AppId, &fx.slot()), None, "the old key stayed in the app-ID group");
    assert!(names_in(Store::Keys).iter().all(|n| !n.contains(".m.")));
    assert_eq!(held(Store::Keys, &machine_slot_name()), Some(other.to_vec()), "another identity's machine key went");
}

/// The machine slot 0.13 shared: its protected copy of the old key goes once no
/// login item mirrors it, and stays (inert) while one does, so no start copies it back.
#[test]
fn a_machine_slot_copy_of_the_old_key_goes_only_when_no_login_item_mirrors_it() {
    for mirrored in [true, false] {
        let fx = Fx::new(&K1);
        plant(Store::Keys, &machine_slot_name(), &K1);
        if mirrored {
            old_build_writes(&machine_slot_name(), &K1);
        }
        let _ = fx.start();
        fx.inert(&K1, 0x41).unwrap();
        assert_eq!(held(Store::Keys, &machine_slot_name()).is_some(), mirrored, "mirrored {mirrored}");
        let _ = take_writes();
        let (moved, _) = fx.start();
        assert!(!moved.news() && take_writes() == 0, "mirrored {mirrored}: {moved:?}");
    }
}

/// A device file a login key opens beside a master it does not (a pair some
/// earlier cut left) is re-keyed too.
#[test]
fn a_device_file_a_login_key_opens_is_rekeyed_too() {
    let fx = Fx::new(&K1);
    let own = [0x17; 32];
    std::fs::write(fx.dir().join(KEY_FILE), seal(&plain(0x41), &own)).unwrap();
    set_profile(fx.dir(), &own);
    assert_eq!(fx.start().1, Rekey::Rekeyed { stay: 1 });
    fx.inert(&K1, 0x41).unwrap();
    assert!(fx.unlocks(0x41));
}

/// Nothing re-keys where the keychain is not macOS's.
#[test]
fn other_platforms_never_rekey() {
    use_mac_layout(Some(false));
    let tmp = crate::test_tmp::tempdir().unwrap();
    let sealed = seal(&plain(0x41), &K1);
    std::fs::write(tmp.path().join(KEY_FILE), &sealed).unwrap();
    set_profile(tmp.path(), &K1);
    assert_eq!(settle(tmp.path()), Rekey::Nothing);
    assert_eq!(std::fs::read(tmp.path().join(KEY_FILE)).unwrap(), sealed);
}


/// The re-key runs at start, before any window: it never reads the login keychain
/// with prompts allowed (a login item whose ACL does not trust this build, or a
/// locked keychain, would put a dialog on screen at launch).
#[test]
fn a_start_reads_the_login_keychain_only_without_prompts() {
    {
        let fx = Fx::new(&K1);
        inject(Fault::LegacyAsks);
        let _ = take_loud_legacy_reads();
        let _ = fx.start();
        assert_eq!(take_loud_legacy_reads(), 0, "the start read the login keychain with prompts allowed");
    }

    // A login key the quiet read sees, with no protected copy yet: the plan's own key
    // search reaches the login keychain, still quietly.
    let fx = Fx::new(&K1);
    let _ = take_loud_legacy_reads();
    assert!(matches!(settle(fx.dir()), Rekey::Rekeyed { .. }));
    assert_eq!(take_loud_legacy_reads(), 0, "the re-key's key search read the login keychain with prompts allowed");
    let _ = login_keys(fx.dir());
    assert_eq!(take_loud_legacy_reads(), 0, "login_keys read with prompts allowed");
}

/// A phrase restore keeps the replaced pair as identity.key.locked / .device.locked
/// (the same master secret). A login key that opens them opens nothing after the
/// re-key either, and the pair is kept, sealed under the new key.
#[test]
fn the_pair_a_phrase_restore_set_aside_moves_off_the_login_key_too() {
    let k2 = [0x22; 32];
    let fx = Fx::new(&k2);
    std::fs::write(fx.dir().join(LOCKED[0]), seal(&plain(0x41), &K1)).unwrap();
    std::fs::write(fx.dir().join(LOCKED[1]), seal(&plain(0x40), &K1)).unwrap();
    old_build_writes(&machine_slot_name(), &K1);
    let (_, rekey) = fx.start();
    assert!(matches!(rekey, Rekey::Rekeyed { .. }), "{rekey:?}");
    fx.inert(&k2, 0x41).unwrap();
    let profile = <[u8; 32]>::try_from(profile_value(fx.dir()).unwrap().as_slice()).unwrap();
    for (name, seed) in [(LOCKED[0], 0x41), (LOCKED[1], 0x40)] {
        assert!(!opens(&fx.file(name), &K1), "the login key still opens {name}");
        assert_eq!(encryption::decrypt_identity(&fx.file(name), &profile).ok(), Some(plain(seed)), "{name} was not kept");
    }
}

/// A set-aside file that will not write puts every file back as it was, leaves no
/// staged key, and a later start moves all four.
#[test]
fn a_set_aside_file_that_will_not_write_puts_every_file_back() {
    let fx = Fx::new(&K1);
    std::fs::write(fx.dir().join(LOCKED[0]), seal(&plain(0x41), &K1)).unwrap();
    std::fs::write(fx.dir().join(LOCKED[1]), seal(&plain(0x40), &K1)).unwrap();
    let before: Vec<Vec<u8>> = FILES.iter().map(|n| fx.file(n)).collect();
    encryption::test_faults::fail_rename_of(LOCKED[1]);
    let (_, rekey) = fx.start();
    encryption::test_faults::clear();
    assert!(matches!(rekey, Rekey::Failed(_)), "{rekey:?}");
    assert_eq!(FILES.iter().map(|n| fx.file(n)).collect::<Vec<_>>(), before, "a file changed");
    assert!(names_in(Store::Keys).iter().all(|n| !n.ends_with(".rekey")), "a staged key stayed");
    assert_eq!(fx.start().1, Rekey::Rekeyed { stay: 1 });
    fx.inert(&K1, 0x41).unwrap();
    assert!(!opens(&fx.file(LOCKED[1]), &K1));
}

/// Two staged values (one per protected group): the files open with one. No start
/// deletes it, and the re-key finishes on it.
#[test]
fn a_staged_key_the_files_need_is_never_unstaged() {
    use_mac_layout(Some(true));
    reset_fakes();
    let tmp = crate::test_tmp::tempdir().unwrap();
    let dir = tmp.path();
    let s1 = [0x31u8; 32];
    std::fs::write(dir.join(KEY_FILE), seal(&plain(0x41), &s1)).unwrap();
    std::fs::write(dir.join(DEVICE_FILE), seal(&plain(0x42), &s1)).unwrap();
    plant(Store::Keys, &profile_slot_name(dir), &[0x0f; 32]);
    plant(Store::Keys, &rekey_slot_name(dir), &[0x32; 32]);
    plant(Store::AppId, &rekey_slot_name(dir), &s1);
    let r = settle(dir);
    let opened = key_that_opens(dir, &std::fs::read(dir.join(KEY_FILE)).unwrap());
    assert!(opened.is_some(), "the re-key deleted the only key that opens the identity ({r:?})");
    assert_eq!(r, Rekey::Finished);
    assert_eq!(profile_value(dir), Some(s1.to_vec()), "the key the files need was not promoted");
    assert!(names_in(Store::Keys).iter().chain(names_in(Store::AppId).iter()).all(|n| !n.ends_with(".rekey")));
}

/// Junk login items under our names that sort first never hide this profile's login
/// item from the re-key, nor from its delete.
#[test]
fn planted_login_items_never_hide_ours_from_the_rekey() {
    let fx = Fx::new(&K1);
    for i in 0..40u64 {
        old_build_writes(&format!("wrapping_key.{i:016x}"), &[0x77; 32]);
    }
    let (_, rekey) = fx.start();
    assert!(!opens(&fx.file(KEY_FILE), &K1), "planted items kept the login key opening the identity ({rekey:?})");
    assert_eq!(rekey, Rekey::Rekeyed { stay: 1 }, "our login item was never tried");
}

/// A start that finishes a cut re-key whose files both opened with the staged key
/// already (an unlock healed the device file) still leaves no copy of the old key.
#[test]
fn a_finishing_start_with_nothing_left_to_write_still_retires_the_old_key() {
    let fx = Fx::new(&K1);
    set_hook(|at, _| at != Step::RekeyKeyFile);
    let _ = fx.start();
    clear_hook();
    assert!(fx.unlocks(0x41));
    plant(Store::Keys, &format!("{}.m.{}", fx.slot(), "cd".repeat(8)), &K1);
    assert_eq!(fx.start().1, Rekey::Finished);
    fx.inert(&K1, 0x41).unwrap();
    assert!(names_in(Store::Keys).iter().all(|n| !n.contains(".m.")), "{:?}", names_in(Store::Keys));
}

/// The unlock's device heal asks the person nothing more once the unlock's own search
/// read the login keychain, and may ask once when it did not.
#[test]
fn a_device_heal_asks_only_when_the_unlock_has_not() {
    for may_ask in [false, true] {
        use_mac_layout(Some(true));
        reset_fakes();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let dir = tmp.path();
        let (ka, kd) = ([0x51u8; 32], [0x52u8; 32]);
        std::fs::write(dir.join(KEY_FILE), seal(&plain(0x41), &ka)).unwrap();
        std::fs::write(dir.join(DEVICE_FILE), seal(&plain(0x42), &kd)).unwrap();
        old_build_writes(&machine_slot_name(), &kd);
        inject(Fault::LegacyAsksPerson);
        let _ = take_loud_legacy_reads();
        heal_device_file(dir, &ka, may_ask);
        let healed = opens(&std::fs::read(dir.join(DEVICE_FILE)).unwrap(), &ka);
        let asked = take_loud_legacy_reads();
        clear_faults();
        assert_eq!(healed, may_ask, "may ask {may_ask}");
        assert_eq!(asked > 0, may_ask, "may ask {may_ask}: {asked} reads that could ask");
    }
}

const PW: &str = "correct horse battery";

impl Fx {
    /// A `0x03` identity (password, its key cached for a silent start) whose cached
    /// key 0.13 left in the login keychain. Answers that key.
    fn password() -> (Self, [u8; 32]) {
        let derives = crate::node::resolver::test_lock();
        use_mac_layout(Some(true));
        reset_fakes();
        let fx = Self { tmp: crate::test_tmp::tempdir().unwrap(), _derives: Some(derives) };
        let salt = [0x23u8; 16];
        let key = encryption::derive_wrapping_key_from_password(PW, &salt).unwrap();
        let master = encryption::encrypt_with_flags(&plain(0x41), &key, &salt, 0x03).unwrap();
        let device = encryption::encrypt_with_flags(&plain(0x42), &key, &[0x77; 16], 0x03).unwrap();
        std::fs::write(fx.dir().join(KEY_FILE), master).unwrap();
        std::fs::write(fx.dir().join(DEVICE_FILE), device).unwrap();
        old_build_writes(&fx.slot(), &key);
        inject(Fault::LegacyNotOwner);
        (fx, key)
    }

    /// The key the password derives under `identity.key`'s salt now.
    fn typed_key(&self) -> [u8; 32] {
        let salt = match encryption::detect_format(&self.file(KEY_FILE)).unwrap() {
            encryption::IdentityFormat::Encrypted { salt, .. } => salt,
            encryption::IdentityFormat::Plaintext => panic!("plaintext"),
        };
        encryption::derive_wrapping_key_from_password(PW, &salt).unwrap()
    }

    /// The password goal: the old key opens neither file, the password opens both
    /// (the device heal included), the profile slot caches exactly that key, both
    /// files keep their flags, and no staged key is left.
    fn inert_password(&self, old: &[u8; 32]) -> Result<(), String> {
        for name in [KEY_FILE, DEVICE_FILE] {
            if opens(&self.file(name), old) {
                return Err(format!("the old key still opens {name}"));
            }
            if flags_of(&self.file(name)) != Some(0x03) {
                return Err(format!("{name} changed its protection"));
            }
        }
        let typed = self.typed_key();
        if profile_value(self.dir()).as_deref() != Some(&typed[..]) {
            return Err("the profile slot does not cache the password's key".into());
        }
        if encryption::decrypt_identity(&self.file(KEY_FILE), &typed).ok() != Some(plain(0x41))
            || encryption::decrypt_identity(&self.file(DEVICE_FILE), &typed).ok() != Some(plain(0x42))
        {
            return Err("the password does not open both files".into());
        }
        if names_in(Store::Keys).iter().any(|n| n.ends_with(".rekey")) {
            return Err(format!("a staged key stayed: {:?}", names_in(Store::Keys)));
        }
        Ok(())
    }
}

/// A `0x03` cached key 0.13 left in a login item opens nothing after one typed
/// unlock: the password's key moves under a fresh salt, and the start after it
/// finds nothing to do.
#[test]
fn a_password_cached_key_in_a_login_item_moves_under_a_fresh_salt_at_a_typed_unlock() {
    let (fx, old) = Fx::password();
    assert_eq!(fx.start().1, Rekey::PasswordKey);
    assert!(wants_password(fx.dir()));
    let (rekey, now) = resalt(fx.dir(), PW);
    assert_eq!(rekey, Rekey::Rekeyed { stay: 1 });
    assert_eq!(now.map(|k| *k), Some(fx.typed_key()), "the unlock was not handed the new key");
    fx.inert_password(&old).unwrap();
    assert!(!wants_password(fx.dir()));
    let _ = take_writes();
    let (moved, rekey) = fx.start();
    assert!(!moved.news() && rekey == Rekey::Nothing && take_writes() == 0, "{moved:?} {rekey:?}");
    assert_eq!(resalt(fx.dir(), PW).0, Rekey::Nothing, "a second typed unlock found work");
}

/// A re-salt killed after any step still opens (silently and with the password),
/// and the next start or typed unlock finishes it.
#[test]
fn a_resalt_killed_at_any_step_still_opens_and_finishes() {
    let steps = [
        Step::RekeyStaged,
        Step::RekeyKeyFile,
        Step::RekeyDeviceFile,
        Step::RekeyLockedFiles,
        Step::RekeyPromoted,
        Step::RekeyUnstaged,
    ];
    for die_at in steps {
        for typed_next in [false, true] {
            let (fx, old) = Fx::password();
            let _ = fx.start();
            set_hook(move |at, _| at != die_at);
            let (rekey, _) = resalt(fx.dir(), PW);
            clear_hook();
            assert_eq!(rekey, Rekey::Died, "{die_at:?}: the hook never fired");
            assert!(fx.both_open_somehow(), "{die_at:?}: a file no stored key opens");
            assert!(fx.unlocks(0x41), "{die_at:?}: no silent unlock after the kill");
            let typed = fx.typed_key();
            assert!(opens(&fx.file(KEY_FILE), &typed), "{die_at:?}: the password no longer opens identity.key");
            if !typed_next {
                let _ = fx.start();
            }
            // Cut before identity.key took the new key, only the password can go on.
            let _ = resalt(fx.dir(), PW);
            fx.inert_password(&old).map_err(|e| format!("{die_at:?}, typed next {typed_next}: {e}")).unwrap();
            assert!(fx.unlocks(0x41), "{die_at:?}: no silent unlock after the finish");
        }
    }
}

/// The duress slot is not the identity's: a re-salt never touches it.
#[test]
fn a_resalt_changes_only_the_identitys_files() {
    let (fx, _) = Fx::password();
    std::fs::write(fx.dir().join("identity.duress"), b"duress slot").unwrap();
    let _ = fx.start();
    assert!(matches!(resalt(fx.dir(), PW).0, Rekey::Rekeyed { .. }));
    assert_eq!(fx.file("identity.duress"), b"duress slot");
}

/// A set-aside password pair moves with the live one when the typed password is its
/// password too, and the same password opens it after; a set-aside password file
/// whose password is another is left as it is.
#[test]
fn a_set_aside_password_pair_moves_only_with_its_own_password() {
    for same_password in [true, false] {
        let (fx, old) = Fx::password();
        let (secret, salt) = (if same_password { PW } else { "another one" }, [0x29u8; 16]);
        let lk = encryption::derive_wrapping_key_from_password(secret, &salt).unwrap();
        let locked = encryption::encrypt_with_flags(&plain(0x41), &lk, &salt, 0x03).unwrap();
        std::fs::write(fx.dir().join(LOCKED[0]), &locked).unwrap();
        old_build_writes(&machine_slot_name(), &lk);
        let _ = fx.start();
        let _ = resalt(fx.dir(), PW);
        fx.inert_password(&old).unwrap();
        let now = fx.file(LOCKED[0]);
        if same_password {
            assert!(!opens(&now, &lk), "the login key still opens the set-aside master");
            assert!(password_key(PW, &now).is_some(), "the password no longer opens the set-aside master");
        } else {
            assert_eq!(now, locked, "a set-aside file another password locks was changed");
        }
    }
}

/// A finishing start whose device file will not write keeps the staged key the
/// already moved `identity.key` needs.
#[test]
fn a_finishing_start_that_cannot_write_keeps_the_staged_key_the_files_need() {
    let fx = Fx::new(&K1);
    set_hook(|at, _| at != Step::RekeyKeyFile);
    let _ = fx.start();
    clear_hook();
    encryption::test_faults::fail_rename_of(DEVICE_FILE);
    let (_, rekey) = fx.start();
    encryption::test_faults::clear();
    assert!(matches!(rekey, Rekey::Failed(_)), "{rekey:?}");
    assert!(fx.both_open_somehow(), "the staged key identity.key needs was deleted");
    let _ = fx.start();
    fx.inert(&K1, 0x41).unwrap();
}

/// A device file no key we hold opens stops the re-key before anything is staged or
/// written: the pair is never split further.
#[test]
fn a_device_file_no_key_opens_stops_the_rekey_before_anything_changes() {
    let fx = Fx::new(&K1);
    std::fs::write(fx.dir().join(DEVICE_FILE), seal(&plain(0x42), &[0x5e; 32])).unwrap();
    let before = (fx.file(KEY_FILE), fx.file(DEVICE_FILE));
    let (_, rekey) = fx.start();
    assert!(matches!(rekey, Rekey::Failed(_)), "{rekey:?}");
    assert_eq!((fx.file(KEY_FILE), fx.file(DEVICE_FILE)), before, "a file changed");
    assert!(names_in(Store::Keys).iter().all(|n| !n.ends_with(".rekey")), "a key was staged");
}

/// A login key that opens only the pair a phrase restore set aside is exposure too.
#[test]
fn a_login_key_that_opens_only_the_set_aside_pair_still_rekeys() {
    use_mac_layout(Some(true));
    reset_fakes();
    let tmp = crate::test_tmp::tempdir().unwrap();
    let dir = tmp.path();
    let own = [0x53u8; 32];
    std::fs::write(dir.join(KEY_FILE), seal(&plain(0x41), &own)).unwrap();
    std::fs::write(dir.join(DEVICE_FILE), seal(&plain(0x42), &own)).unwrap();
    set_profile(dir, &own);
    std::fs::write(dir.join(LOCKED[0]), seal(&plain(0x41), &K1)).unwrap();
    old_build_writes(&machine_slot_name(), &K1);
    assert!(matches!(settle(dir), Rekey::Rekeyed { .. }));
    assert!(!opens(&std::fs::read(dir.join(LOCKED[0])).unwrap(), &K1), "the login key still opens the set-aside master");
}
