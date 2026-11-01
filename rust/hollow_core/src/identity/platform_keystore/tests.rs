use super::test_support::*;
use super::*;

/// The macOS layout on any host, with the bundle self-check passed.
fn mac() {
    use_mac_layout(Some(true));
}

/// A keychain-only identity file sealed under `key`.
fn sealed(seed: u8, key: &[u8; 32]) -> Vec<u8> {
    let plain = crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[seed; 32])
        .to_protobuf_encoding()
        .unwrap();
    crate::identity::encryption::encrypt_identity(&plain, key, &[0u8; 16], false, true).unwrap()
}

fn root(name: &str) -> PathBuf {
    PathBuf::from(format!("/hollow-test-roots/{name}"))
}

#[test]
fn test_builds_never_name_a_real_slot() {
    assert!(WIN_BASE.contains(".test."), "a test build names the real Windows slot");
    let root = Path::new("/somewhere/hollow");
    assert!(!profile_slot(root).starts_with("com.hollow.identity."));
    assert!(!legacy_slot().starts_with("com.hollow.identity"));
}

/// A store, a move and a wipe run with prompts off: a session with no keychain (ssh)
/// fails them quietly instead of raising a dialog on someone's screen.
#[test]
fn a_keychain_store_never_asks_the_person() {
    let tmp = crate::test_tmp::tempdir().unwrap();
    let _ = take_loud_writes();
    store_key_at(tmp.path(), &[0x5c; 32]).unwrap();
    assert_eq!(read_profile_key_at(tmp.path()).unwrap(), Some(vec![0x5c; 32]));
    assert_eq!(take_loud_writes(), 0, "a keychain write was allowed to ask");

    mac();
    old_build_writes(&profile_slot_name(&root("a")), &[0x5d; 32]);
    store_key_at(tmp.path(), &[0x5e; 32]).unwrap();
    assert_eq!(settle_move(&root("a")).moved, 1);
    forget_key_at(tmp.path(), None);
    assert_eq!(take_loud_writes(), 0, "a macOS keychain write was allowed to ask");
}

/// The suffix names every existing per-profile slot, so it never changes.
#[test]
fn slot_suffix_is_pinned() {
    assert_eq!(slot_suffix(Path::new("/tmp/a")), "d9b741ea3d4d24a6");
    assert_ne!(slot_suffix(Path::new("/tmp/a")), slot_suffix(Path::new("/tmp/b")));
}

#[test]
fn a_profile_slot_outranks_the_legacy_slot_and_the_blob() {
    let tmp = crate::test_tmp::tempdir().unwrap();
    set_legacy(&[0xB2; 32]);
    store_key_at(tmp.path(), &[0xA1; 32]).unwrap();
    let cands = candidates_at(tmp.path());
    assert_eq!(cands.first(), Some(&(Source::Profile, vec![0xA1; 32])));
    assert!(cands.iter().any(|(s, k)| matches!(s, Source::Legacy | Source::Unmoved) && *k == vec![0xB2; 32]));
    assert_eq!(read_blob_key_at(tmp.path()), Some(vec![0xA1; 32]));
}

/// Storing a key for one profile leaves the machine-wide legacy slot alone.
#[test]
fn storing_never_writes_the_legacy_slot() {
    let tmp = crate::test_tmp::tempdir().unwrap();
    set_legacy(&[0x33; 32]);
    store_key_at(tmp.path(), &[0x44; 32]).unwrap();
    assert_eq!(legacy_value(), Some(vec![0x33; 32]));
}

#[test]
fn a_snapshot_puts_back_what_was_there() {
    let tmp = crate::test_tmp::tempdir().unwrap();
    let empty = snapshot_at(tmp.path());
    store_key_at(tmp.path(), &[0x11; 32]).unwrap();
    restore_snapshot(tmp.path(), &empty);
    assert_eq!(profile_value(tmp.path()), None);
    assert!(!tmp.path().join(BLOB).exists());

    store_key_at(tmp.path(), &[0x22; 32]).unwrap();
    let held = snapshot_at(tmp.path());
    store_key_at(tmp.path(), &[0x33; 32]).unwrap();
    restore_snapshot(tmp.path(), &held);
    assert_eq!(profile_value(tmp.path()), Some(vec![0x22; 32]));
    assert_eq!(read_blob_key_at(tmp.path()), Some(vec![0x22; 32]));
}

#[cfg(windows)]
#[test]
fn dpapi_round_trip() {
    let secret = b"hollow-test-wrapping-key-32bytes!";
    let protected = win::dpapi_protect(secret).unwrap();
    assert_ne!(protected, secret.to_vec());
    assert!(protected.len() > secret.len());
    assert_eq!(win::dpapi_unprotect(&protected).unwrap(), secret.to_vec());
    let empty = win::dpapi_protect(b"").unwrap();
    assert_eq!(win::dpapi_unprotect(&empty).unwrap(), Vec::<u8>::new());
}

/// The real store, in the test namespace: a write reads back through a new call,
/// and a delete is gone. Skipped where there is no keystore a test binary may use.
#[test]
fn the_real_keystore_round_trips_in_the_test_namespace() {
    let Some(_real) = RealKeystore::enter() else { return };
    let tmp = crate::test_tmp::tempdir().unwrap();
    let key = vec![0x42u8; 32];
    store_key_at(tmp.path(), &key).unwrap();
    assert_eq!(read_profile_key_at(tmp.path()).unwrap(), Some(key.clone()));
    if cfg!(windows) {
        assert_eq!(read_blob_key_at(tmp.path()), Some(key.clone()));
    }
    forget_key_at(tmp.path(), None);
    assert_eq!(read_profile_key_at(tmp.path()).unwrap(), None);
    assert_eq!(read_blob_key_at(tmp.path()), None);
}

// -- macOS: the move into the data-protection keychain (HOL-SEC-187) --

#[test]
fn a_legacy_key_moves_into_the_protected_keychain_then_leaves() {
    mac();
    let r = root("a");
    let slot = profile_slot_name(&r);
    old_build_writes(&slot, &[0x11; 32]);
    let moved = settle_move(&r);
    assert_eq!(moved, Moved { moved: 1, kept: 0, skipped: 0 });
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x11; 32]), "the key did not arrive byte for byte");
    assert!(names_in(Store::Legacy).is_empty(), "the login keychain item stayed");
    let identity = sealed(1, &[0x11; 32]);
    assert_eq!(key_that_opens(&r, &identity), Some((Source::Profile, [0x11; 32])));
    assert_eq!(settle_move(&r), Moved::default(), "a second start found work");
}

/// Dying at any step keeps the key in at least one store, and the next start
/// finishes the move.
#[test]
fn a_move_cut_short_keeps_both_and_finishes_at_the_next_start() {
    for die_at in [Step::Read, Step::Copied, Step::ReadBack, Step::Deleted] {
        mac();
        let r = root(&format!("cut-{die_at:?}"));
        let slot = profile_slot_name(&r);
        old_build_writes(&slot, &[0x21; 32]);
        set_hook(move |at, _| at != die_at);
        let _ = settle_move(&r);
        clear_hook();
        let somewhere = held(Store::Legacy, &slot).or(held(Store::Keys, &slot));
        assert_eq!(somewhere, Some(vec![0x21; 32]), "dying at {die_at:?} lost the key");
        let _ = settle_move(&r);
        assert_eq!(held(Store::Keys, &slot), Some(vec![0x21; 32]), "{die_at:?}: never finished");
        assert!(held(Store::Legacy, &slot).is_none(), "{die_at:?}: the old item stayed");
        assert!(names_in(Store::Keys).iter().all(|n| !n.contains(COPY_MARK)), "{die_at:?}: a copy for an equal key");
        fake_remove(Store::Keys, &slot);
    }
}

#[test]
fn a_protected_copy_that_does_not_read_back_keeps_the_legacy_key() {
    for f in [Fault::ReadBackMissing, Fault::ReadBackWrong, Fault::StoreFails] {
        mac();
        let r = root(&format!("rb-{f:?}"));
        let slot = profile_slot_name(&r);
        old_build_writes(&slot, &[0x31; 32]);
        let _ = protected_writable();
        inject(f);
        let moved = settle_move(&r);
        clear_faults();
        assert_eq!(moved.moved, 0, "{f:?}: moved without a copy that reads back");
        assert_eq!(held(Store::Legacy, &slot), Some(vec![0x31; 32]), "{f:?}: the old item went");
        fake_remove(Store::Keys, &slot);
        fake_remove(Store::Legacy, &slot);
    }
}

/// Step 5: a delete that answers success but leaves the item counts as kept, and
/// the next start finishes it.
#[test]
fn a_delete_that_does_not_take_is_never_counted_as_moved() {
    mac();
    let r = root("delete-stays");
    let slot = profile_slot_name(&r);
    old_build_writes(&slot, &[0x32; 32]);
    let _ = protected_writable();
    inject(Fault::DeleteRefLeaves);
    let moved = settle_move(&r);
    clear_faults();
    assert_eq!(moved, Moved { moved: 0, kept: 1, skipped: 0 }, "a delete that did not take was counted");
    assert_eq!(held(Store::Legacy, &slot), Some(vec![0x32; 32]));
    assert_eq!(settle_move(&r), Moved { moved: 1, kept: 0, skipped: 0 }, "the next start did not finish it");
    assert!(held(Store::Legacy, &slot).is_none());
}

/// An old build rewrites the item between the read and the delete: the delete
/// misses the new item, and the next start keeps both keys.
#[test]
fn a_legacy_key_rewritten_during_the_move_is_never_deleted() {
    mac();
    let r = root("rw");
    let slot = profile_slot_name(&r);
    old_build_writes(&slot, &[0x41; 32]);
    let rewrite = slot.clone();
    set_hook(move |at, name| {
        if at == Step::ReadBack && name == rewrite {
            old_build_writes(&rewrite, &[0x42; 32]);
        }
        true
    });
    let _ = settle_move(&r);
    clear_hook();
    assert_eq!(held(Store::Legacy, &slot), Some(vec![0x42; 32]), "the rewritten key was deleted");
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x41; 32]));
    let _ = settle_move(&r);
    assert!(held(Store::Legacy, &slot).is_none());
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x41; 32]), "the protected key was overwritten");
    assert_eq!(held(Store::Keys, &copy_name(&slot, &[0x42; 32])), Some(vec![0x42; 32]), "the newer key was lost");
}

#[test]
fn two_movers_at_once_keep_every_key() {
    for at_step in [Step::Read, Step::Copied, Step::ReadBack] {
        mac();
        let r = root(&format!("two-{at_step:?}"));
        let slot = profile_slot_name(&r);
        let other = format!("{MAC_BASE}.{}", "ab".repeat(8));
        old_build_writes(&slot, &[0x51; 32]);
        old_build_writes(&other, &[0x52; 32]);
        let inner = r.clone();
        let mut once = true;
        set_hook(move |at, _| {
            if at == at_step && std::mem::take(&mut once) {
                let _ = settle_move(&inner);
            }
            true
        });
        let _ = settle_move(&r);
        clear_hook();
        assert_eq!(held(Store::Keys, &slot), Some(vec![0x51; 32]), "{at_step:?}");
        assert_eq!(held(Store::Keys, &other), Some(vec![0x52; 32]), "{at_step:?}");
        assert!(names_in(Store::Legacy).is_empty(), "{at_step:?}: {:?}", names_in(Store::Legacy));
        assert_eq!(names_in(Store::Keys).len(), 2, "{at_step:?}: {:?}", names_in(Store::Keys));
        fake_remove(Store::Keys, &slot);
        fake_remove(Store::Keys, &other);
    }
}

#[test]
fn a_conflicting_legacy_key_never_overwrites_the_protected_one() {
    mac();
    let r = root("conflict");
    let slot = profile_slot_name(&r);
    plant(Store::Keys, &slot, &[0x61; 32]);
    old_build_writes(&slot, &[0x62; 32]);
    assert_eq!(settle_move(&r).moved, 1);
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x61; 32]));
    let copy = copy_name(&slot, &[0x62; 32]);
    assert!(copy.starts_with(&format!("{slot}.m.")), "a copy not named after its root: {copy}");
    assert_eq!(held(Store::Keys, &copy), Some(vec![0x62; 32]));
    assert!(names_in(Store::Legacy).is_empty());
    // The copy opens the identity it belongs to.
    assert_eq!(key_that_opens(&r, &sealed(2, &[0x62; 32])), Some((Source::Copy, [0x62; 32])));
}

#[test]
fn a_wipe_forgets_the_conflict_copies_too() {
    mac();
    let tmp = crate::test_tmp::tempdir().unwrap();
    let slot = profile_slot_name(tmp.path());
    plant(Store::Keys, &slot, &[0x71; 32]);
    old_build_writes(&slot, &[0x72; 32]);
    let _ = settle_move(tmp.path());
    plant(Store::AppId, &copy_name(&slot, &[0x73; 32]), &[0x73; 32]);
    forget_key_at(tmp.path(), Some(&sealed(3, &[0x72; 32])));
    let left: Vec<String> = [Store::Keys, Store::AppId, Store::Legacy]
        .iter()
        .flat_map(|s| names_in(*s))
        .filter(|n| n.starts_with(&slot))
        .collect();
    assert!(left.is_empty(), "the wipe left {left:?}");
}

#[test]
fn heal_leaves_no_conflict_copy_behind() {
    mac();
    let r = root("heal");
    let slot = profile_slot_name(&r);
    plant(Store::Keys, &copy_name(&slot, &[0x81; 32]), &[0x81; 32]);
    plant(Store::AppId, &copy_name(&slot, &[0x82; 32]), &[0x82; 32]);
    drop_copies(&r);
    assert!(names_in(Store::Keys).is_empty() && names_in(Store::AppId).is_empty());
}

/// Only our slot names with 32-byte values move; anything else is never touched.
#[test]
fn planted_legacy_items_are_not_moved() {
    mac();
    let r = root("planted");
    let planted = [
        ("wrapping_key.zz".to_string(), vec![1u8; 32]),
        ("other".to_string(), vec![2u8; 32]),
        (format!("wrapping_key.{}", "AB".repeat(8)), vec![3u8; 32]),
        (format!("wrapping_key.{}", "ab".repeat(8)), vec![4u8; 31]),
        (format!("wrapping_key.{}.m.{}", "ab".repeat(8), "cd".repeat(8)), vec![5u8; 32]),
        (format!("wrapping_key.{}x", "ab".repeat(8)), vec![6u8; 32]),
    ];
    for (name, value) in &planted {
        old_build_writes(name, value);
    }
    let moved = settle_move(&r);
    assert_eq!(moved.moved, 0, "{:?}", names_in(Store::Keys));
    assert!(names_in(Store::Keys).is_empty());
    assert_eq!(names_in(Store::Legacy).len(), planted.len(), "a planted item was deleted");
}

#[test]
fn a_flood_of_planted_slots_never_holds_back_our_own() {
    mac();
    let r = root("flood");
    for i in 0..(MOVE_LIMIT + 8) {
        old_build_writes(&format!("wrapping_key.{i:016x}"), &[0x90; 32]);
    }
    let slot = profile_slot_name(&r);
    old_build_writes(&slot, &[0x91; 32]);
    old_build_writes(&machine_slot_name(), &[0x92; 32]);
    let moved = settle_move(&r);
    assert_eq!(moved.moved, MOVE_LIMIT, "one start moved more than its limit");
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x91; 32]), "our slot waited behind planted ones");
    assert_eq!(held(Store::Keys, &machine_slot_name()), Some(vec![0x92; 32]));
}

#[test]
fn every_profiles_slot_moves_not_only_the_running_one() {
    mac();
    let (a, b) = (root("one"), root("two"));
    old_build_writes(&profile_slot_name(&a), &[0xa1; 32]);
    old_build_writes(&profile_slot_name(&b), &[0xb1; 32]);
    assert_eq!(settle_move(&a).moved, 2);
    assert_eq!(held(Store::Keys, &profile_slot_name(&b)), Some(vec![0xb1; 32]));
    assert!(names_in(Store::Legacy).is_empty());
}

#[test]
fn the_machine_slot_moves_once_and_is_never_written() {
    mac();
    let tmp = crate::test_tmp::tempdir().unwrap();
    let machine = machine_slot_name();
    old_build_writes(&machine, &[0xc1; 32]);
    let _ = take_writes();
    assert_eq!(settle_move(tmp.path()).moved, 1);
    assert_eq!(take_writes(), 1, "the move wrote more than the one copy");
    assert_eq!(held(Store::Keys, &machine), Some(vec![0xc1; 32]));
    store_key_at(tmp.path(), &[0xc2; 32]).unwrap();
    let _ = settle_move(tmp.path());
    assert_eq!(held(Store::Keys, &machine), Some(vec![0xc1; 32]), "the machine slot was written");
    assert_eq!(take_writes(), 1, "only the profile slot is ever stored");
    // A wipe of an identity it does not open keeps it; one it opens takes it.
    forget_key_at(tmp.path(), Some(&sealed(4, &[0xc2; 32])));
    assert_eq!(held(Store::Keys, &machine), Some(vec![0xc1; 32]), "the machine slot of another identity went");
    forget_key_at(tmp.path(), Some(&sealed(4, &[0xc1; 32])));
    assert_eq!(held(Store::Keys, &machine), None);
}

/// A machine-slot conflict copy goes with a wipe only when its own key opens the
/// identity being wiped: another profile may still need the other one.
#[test]
fn a_wipe_takes_only_the_machine_items_that_open_its_identity() {
    mac();
    let tmp = crate::test_tmp::tempdir().unwrap();
    let machine = machine_slot_name();
    plant(Store::Keys, &machine, &[0xd1; 32]);
    plant(Store::Keys, &copy_name(&machine, &[0xd2; 32]), &[0xd2; 32]);
    forget_key_at(tmp.path(), Some(&sealed(5, &[0xd2; 32])));
    assert_eq!(held(Store::Keys, &machine), Some(vec![0xd1; 32]));
    assert_eq!(held(Store::Keys, &copy_name(&machine, &[0xd2; 32])), None);
}

#[test]
fn an_item_in_the_app_id_group_opens_and_moves_once_the_keys_group_works() {
    mac();
    let r = root("appid");
    let slot = profile_slot_name(&r);
    old_build_writes(&slot, &[0xe1; 32]);
    inject(Fault::KeysRefused);
    assert_eq!(protected_writable(), Writable::Yes(Store::AppId));
    assert_eq!(settle_move(&r).moved, 1);
    assert_eq!(held(Store::AppId, &slot), Some(vec![0xe1; 32]));
    let identity = sealed(6, &[0xe1; 32]);
    assert_eq!(key_that_opens(&r, &identity), Some((Source::Profile, [0xe1; 32])));

    // A later macOS accepts the keys group: the next start promotes the item.
    clear_faults();
    use_mac_layout(Some(true));
    assert_eq!(protected_writable(), Writable::Yes(Store::Keys));
    assert_eq!(settle_move(&r).moved, 1);
    assert_eq!(held(Store::Keys, &slot), Some(vec![0xe1; 32]));
    assert!(names_in(Store::AppId).is_empty(), "the app-ID item stayed");
    assert_eq!(key_that_opens(&r, &identity), Some((Source::Profile, [0xe1; 32])));
}

/// Store rule 1: no flow writes the file-based keychain.
#[test]
fn no_flow_writes_the_legacy_keychain() {
    mac();
    let tmp = crate::test_tmp::tempdir().unwrap();
    old_build_writes(&profile_slot_name(tmp.path()), &[0xf1; 32]);
    old_build_writes(&machine_slot_name(), &[0xf2; 32]);
    let _ = take_legacy_writes();
    let _ = settle_move(tmp.path());
    store_key_at(tmp.path(), &[0xf3; 32]).unwrap();
    let snap = snapshot_at(tmp.path());
    store_key_at(tmp.path(), &[0xf4; 32]).unwrap();
    restore_snapshot(tmp.path(), &snap);
    let _ = key_that_opens(tmp.path(), &sealed(7, &[0xf2; 32]));
    forget_key_at(tmp.path(), Some(&sealed(7, &[0xf2; 32])));
    inject(Fault::KeysRefused);
    inject(Fault::AppIdRefused);
    use_mac_layout(Some(true));
    let _ = store_key_at(tmp.path(), &[0xf5; 32]);
    assert_eq!(take_legacy_writes(), 0);
    assert_eq!(add(Store::Legacy, "wrapping_key", &[0; 32]), Err(Failure::Other(-4)));
    assert_eq!(put(Store::Legacy, "wrapping_key", &[0; 32]), Err(Failure::Other(-4)));
}

/// Nothing in hollow_core may call an API that writes the file-based keychain.
#[test]
fn no_source_writes_the_legacy_keychain() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let banned = ["set_generic_password", "SecKeychainAddGenericPassword", "SecKeychainItemModify", "add_generic_password"];
    let mut found = Vec::new();
    let mut stack = vec![src];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|e| e == "rs") && !path.ends_with("platform_keystore/tests.rs") {
                let text = std::fs::read_to_string(&path).unwrap();
                for word in banned {
                    if text.contains(word) {
                        found.push(format!("{}: {word}", path.display()));
                    }
                }
            }
        }
    }
    assert!(found.is_empty(), "file-based keychain writes: {found:?}");
    let this = std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("src/identity/platform_keystore.rs")).unwrap();
    assert_eq!(this.matches("SecItemAdd(").count(), 2, "a new SecItemAdd call site: it must sit in mac::add");
}

#[test]
fn a_missing_entitlement_keeps_the_legacy_key_and_deletes_nothing() {
    mac();
    let r = root("refused");
    let slot = profile_slot_name(&r);
    old_build_writes(&slot, &[0x13; 32]);
    old_build_writes(&machine_slot_name(), &[0x14; 32]);
    inject(Fault::KeysRefused);
    inject(Fault::AppIdRefused);
    assert_eq!(protected_writable(), Writable::No);
    assert!(!may_offer());
    assert_eq!(settle_move(&r), Moved::default());
    assert!(store_key_at(&r, &[0x15; 32]).is_err());
    assert_eq!(names_in(Store::Legacy).len(), 2, "a key was deleted");
    let identity = sealed(8, &[0x13; 32]);
    assert_eq!(key_that_opens(&r, &identity), Some((Source::Unmoved, [0x13; 32])), "the unmoved key stopped opening");
}

#[test]
fn an_unknown_probe_is_not_cached() {
    mac();
    let _ = take_probes();
    inject(Fault::ProbeUnknown);
    assert_eq!(protected_writable(), Writable::Unknown);
    assert_eq!(protected_writable(), Writable::Unknown);
    assert_eq!(take_probes(), 2, "an unknown answer was kept for the process");
    assert!(!may_offer());
    let r = root("unknown");
    old_build_writes(&profile_slot_name(&r), &[0x16; 32]);
    assert_eq!(settle_move(&r), Moved::default(), "an unknown answer moved a key");
    clear_faults();
    let _ = take_probes();
    assert_eq!(protected_writable(), Writable::Yes(Store::Keys));
    assert_eq!(protected_writable(), Writable::Yes(Store::Keys));
    assert_eq!(take_probes(), 1, "a definite answer was asked again");
}

#[test]
fn the_protected_store_reads_nothing_before_the_bundle_check() {
    mac();
    let r = root("unchecked");
    let slot = profile_slot_name(&r);
    plant(Store::Keys, &slot, &[0x17; 32]);
    old_build_writes(&machine_slot_name(), &[0x18; 32]);
    set_unchecked(true);
    let _ = take_reads();
    assert_eq!(protected_writable(), Writable::No);
    assert_eq!(key_that_opens(&r, &sealed(9, &[0x17; 32])), None);
    assert_eq!(key_that_opens(&r, &sealed(9, &[0x18; 32])), None);
    assert!(store_key_at(&r, &[0x19; 32]).is_err());
    assert_eq!(settle_move(&r), Moved::default());
    forget_key_at(&r, Some(&sealed(9, &[0x18; 32])));
    assert!(take_reads().is_empty(), "a keychain read before the bundle check");
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x17; 32]), "a wipe before the check reached the keychain");
    set_unchecked(false);
    assert_eq!(key_that_opens(&r, &sealed(9, &[0x17; 32])), Some((Source::Profile, [0x17; 32])));
}

/// Store rule 2: a write updates the item it finds, never deletes it first.
#[test]
fn a_protected_write_never_deletes_first() {
    mac();
    let r = root("inplace");
    store_key_at(&r, &[0x1a; 32]).unwrap();
    let (_, first) = fake_item(Store::Keys, &profile_slot_name(&r)).unwrap();
    store_key_at(&r, &[0x1b; 32]).unwrap();
    let (value, second) = fake_item(Store::Keys, &profile_slot_name(&r)).unwrap();
    assert_eq!(value, vec![0x1b; 32]);
    assert_eq!(first, second, "the item was deleted and added again");
}

#[test]
fn a_wipe_forgets_the_key_in_both_keychains() {
    mac();
    let tmp = crate::test_tmp::tempdir().unwrap();
    let slot = profile_slot_name(tmp.path());
    plant(Store::Keys, &slot, &[0x1c; 32]);
    plant(Store::AppId, &slot, &[0x1c; 32]);
    old_build_writes(&slot, &[0x1c; 32]);
    old_build_writes(&machine_slot_name(), &[0x1d; 32]);
    plant(Store::Keys, &machine_slot_name(), &[0x1d; 32]);
    forget_key_at(tmp.path(), Some(&sealed(10, &[0x1d; 32])));
    for store in [Store::Keys, Store::AppId, Store::Legacy] {
        assert!(names_in(store).is_empty(), "{store:?} kept {:?}", names_in(store));
    }
}

/// A stale key in the keys group never hides the app-ID group's key that opens the
/// file, before or after the start's move.
#[test]
fn a_stale_keys_group_key_never_hides_the_one_that_opens() {
    mac();
    let r = root("stale-keys");
    let slot = profile_slot_name(&r);
    plant(Store::Keys, &slot, &[0x3a; 32]);
    plant(Store::AppId, &slot, &[0x3b; 32]);
    let identity = sealed(11, &[0x3b; 32]);
    assert_eq!(key_that_opens(&r, &identity), Some((Source::Profile, [0x3b; 32])));
    let _ = settle_move(&r);
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x3a; 32]), "the move overwrote a key");
    assert_eq!(key_that_opens(&r, &identity).map(|(_, k)| k), Some([0x3b; 32]));
}

#[test]
fn only_our_groups_open_the_keychain() {
    assert!(bundle::app_id_group_ok("NWPBHZX7DT.com.anonlisten.hollow"));
    assert!(bundle::app_id_group_ok("XMTJT2AV6F.com.anonlisten.hollow"));
    for bad in ["nwpbhzx7dt.com.anonlisten.hollow", "NWPBHZX7D.com.anonlisten.hollow", "NWPBHZX7DT.com.anonlisten.hollow.dev", "group.com.anonlisten.hollow", ""] {
        assert!(!bundle::app_id_group_ok(bad), "{bad}");
    }
    assert!(!bundle::mark_checked("group.com.anonlisten.hollow", "NWPBHZX7DT.com.anonlisten.hollow"));
    assert!(!bundle::mark_checked(bundle::KEYS_GROUP, "group.com.anonlisten.hollow.keys"));
}
