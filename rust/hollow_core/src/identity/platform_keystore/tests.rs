use super::test_support::*;
use super::*;

/// [`super::key_that_opens`] with the key unwrapped, to compare.
fn key_that_opens(root: &Path, identity: &[u8]) -> Option<(Source, [u8; 32])> {
    super::key_that_opens(root, identity).map(|(source, key)| (source, *key))
}

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

/// (moved, kept, skipped) of a start.
fn counts(m: Moved) -> (usize, usize, usize) {
    (m.moved, m.kept, m.skipped)
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
    assert_eq!(counts(moved), (1, 0, 0));
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
/// the next start finishes it, in both movers.
#[test]
fn a_delete_that_does_not_take_is_never_counted_as_moved() {
    for from in [Store::Legacy, Store::AppId] {
        mac();
        let r = root(&format!("delete-stays-{from:?}"));
        let slot = profile_slot_name(&r);
        match from {
            Store::Legacy => old_build_writes(&slot, &[0x32; 32]),
            _ => plant(from, &slot, &[0x32; 32]),
        }
        let _ = protected_writable();
        inject(Fault::DeleteRefLeaves);
        let moved = settle_move(&r);
        clear_faults();
        assert_eq!(counts(moved), (0, 1, 0), "{from:?}: a delete that did not take was counted");
        assert_eq!(held(from, &slot), Some(vec![0x32; 32]));
        assert_eq!(counts(settle_move(&r)), (1, 0, 0), "{from:?}: the next start did not finish it");
        assert!(held(from, &slot).is_none());
        fake_remove(Store::Keys, &slot);
    }
}

/// A failed copy says which call failed and how, for the start's log.
#[test]
fn a_copy_that_cannot_be_made_says_why() {
    mac();
    let _ = protected_writable();
    inject(Fault::StoreFails);
    assert_eq!(place_copy(Store::Keys, "wrapping_key", &[0x35; 32], false), Err("add Other(-1)".to_string()));
    clear_faults();
    inject(Fault::KeysRefused);
    assert_eq!(place_copy(Store::Keys, "wrapping_key", &[0x35; 32], false), Err("read Refused".to_string()));
}

/// Field report (signed 0.14, macOS 26): a reference lookup that misses file-based
/// items made the delete and its check agree on "gone" while the login item stayed,
/// so every start said "1 moved" and the old build kept opening.
#[test]
fn a_login_item_the_delete_missed_is_never_counted_as_moved() {
    mac();
    let r = root("refs-miss");
    let slot = profile_slot_name(&r);
    old_build_writes(&slot, &[0x34; 32]);
    let _ = protected_writable();
    inject(Fault::LegacyRefsMiss);
    let first = settle_move(&r);
    assert!(held(Store::Legacy, &slot).is_none() || first.moved == 0, "counted as moved while the login item stayed: {first:?}");
    assert!(held(Store::Legacy, &slot).is_none(), "the login item the move read was not deleted");
    assert_eq!(counts(first), (1, 0, 0));
    assert_eq!(settle_move(&r), Moved::default(), "the next start found the item again");
    clear_faults();
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x34; 32]));
}

/// Another process rewrote the login item after the read: the delete answers "not
/// found" while this process's read misses the new key. Counted as kept, never moved,
/// and the next start finishes it.
#[test]
fn a_delete_that_found_nothing_is_never_counted_as_moved() {
    mac();
    let r = root("delete-not-found");
    let slot = profile_slot_name(&r);
    old_build_writes(&slot, &[0x36; 32]);
    let _ = protected_writable();
    inject(Fault::LegacyStaleAfterMiss);
    let first = settle_move(&r);
    clear_faults();
    assert_eq!(counts(first), (0, 1, 0), "a delete that removed nothing was counted as a move");
    assert_eq!(held(Store::Legacy, &slot), Some(vec![0x36; 32]));
    assert_eq!(counts(settle_move(&r)), (1, 0, 0));
    assert!(held(Store::Legacy, &slot).is_none());
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x36; 32]));
}

/// The protected delete names the item's group, service and account besides its
/// reference. Only a signed build can show the data-protection keychain honours them
/// together; an unsigned test binary is refused that keychain.
#[cfg(target_os = "macos")]
#[test]
fn a_protected_delete_by_reference_stays_inside_its_name() {
    assert!(bundle::mark_checked(bundle::KEYS_GROUP, "ABCDE12345.com.anonlisten.hollow"));
    let names = mac::delete_query_names(Store::AppId, "wrapping_key", &Item::Persistent(vec![1, 2, 3])).expect("a query");
    for attr in ["acct", "agrp", "class", "nleg", "svce", "v_PersistentRef"] {
        assert!(names.iter().any(|n| n == attr), "the delete does not name {attr}: {names:?}");
    }
    let file = mac::delete_query_names(Store::Legacy, "wrapping_key", &Item::Persistent(vec![1])).is_none();
    assert!(file, "a file-based delete by persistent reference was built");
}

/// An old build rewrites the item between the read and the delete: the delete
/// misses the new item, and the next start leaves it beside the protected key.
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
    let first = settle_move(&r);
    clear_hook();
    assert_eq!(counts(first), (0, 1, 0), "a name that still holds a key was counted as moved");
    assert_eq!(held(Store::Legacy, &slot), Some(vec![0x42; 32]), "the rewritten key was deleted");
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x41; 32]));
    let second = settle_move(&r);
    assert_eq!((second.left, second.wrote), (1, 0), "{second:?}");
    assert_eq!(held(Store::Legacy, &slot), Some(vec![0x42; 32]), "the newer key was deleted");
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x41; 32]), "the protected key was overwritten");
    assert!(names_in(Store::Keys).iter().all(|n| !n.contains(COPY_MARK)), "a conflict copy of a login key");
}

/// An old build writes a new key just after the delete: the re-read finds it, so the
/// move counts it kept, never moved, and the next start leaves the new one in place.
#[test]
fn a_legacy_key_written_after_the_delete_is_never_counted_as_moved() {
    mac();
    let r = root("after-delete");
    let slot = profile_slot_name(&r);
    old_build_writes(&slot, &[0x44; 32]);
    let rewrite = slot.clone();
    set_hook(move |at, name| {
        if at == Step::Deleted && name == rewrite {
            old_build_writes(&rewrite, &[0x45; 32]);
        }
        true
    });
    let first = settle_move(&r);
    clear_hook();
    assert_eq!(counts(first), (0, 1, 0), "a name that holds a new key was counted as moved");
    assert_eq!(held(Store::Legacy, &slot), Some(vec![0x45; 32]));
    assert_eq!(settle_move(&r).left, 1);
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x44; 32]));
    assert_eq!(held(Store::Legacy, &slot), Some(vec![0x45; 32]), "the newer key was lost");
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
    let moved = settle_move(&r);
    assert_eq!((moved.moved, moved.left, moved.wrote), (0, 1, 0), "{moved:?}");
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x61; 32]));
    assert_eq!(held(Store::Legacy, &slot), Some(vec![0x62; 32]), "a login key with no protected copy was deleted");
    assert!(names_in(Store::Keys).iter().all(|n| !n.contains(COPY_MARK)));
    // The login key still opens the identity it belongs to.
    assert_eq!(key_that_opens(&r, &sealed(2, &[0x62; 32])), Some((Source::Unmoved, [0x62; 32])));
}

#[test]
fn a_wipe_forgets_the_conflict_copies_too() {
    mac();
    let tmp = crate::test_tmp::tempdir().unwrap();
    let slot = profile_slot_name(tmp.path());
    plant(Store::Keys, &slot, &[0x71; 32]);
    old_build_writes(&slot, &[0x72; 32]);
    plant(Store::Keys, &copy_name(&slot, &[0x72; 32]), &[0x72; 32]);
    plant(Store::Keys, &format!("{slot}{REKEY_MARK}"), &[0x74; 32]);
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

/// Field report (signed 0.14, macOS 26): the login keychain lets only the app that
/// made an item delete it. The item is held, logged once with its copy, and a later
/// start tries it again only while its key still opens one of our files.
#[test]
fn a_login_item_only_its_maker_may_delete_is_held_and_tried_again_only_while_it_opens_ours() {
    mac();
    let r = root("not-owner");
    let slot = profile_slot_name(&r);
    old_build_writes(&slot, &[0x37; 32]);
    let _ = protected_writable();
    inject(Fault::LegacyNotOwner);
    let first = settle_move_judged(&r, &|_| true);
    assert_eq!((first.moved, first.kept, first.held, first.wrote), (0, 0, 1, 1), "{first:?}");
    assert!(first.news());
    assert_eq!(held(Store::Legacy, &slot), Some(vec![0x37; 32]));
    assert_eq!(held(Store::Keys, &slot), Some(vec![0x37; 32]));
    // Still ours: tried again, quietly (nothing new to say).
    let again = settle_move_judged(&r, &|_| true);
    assert_eq!((again.held, again.wrote), (1, 0), "{again:?}");
    assert!(!again.news(), "a held item was news again: {again:?}");
    // Opens nothing of ours any more: never tried again (a delete would fail here).
    inject(Fault::DeleteRefFails);
    let after = settle_move_judged(&r, &|_| false);
    clear_faults();
    assert_eq!((after.kept, after.held, after.left), (0, 0, 1), "{after:?}");
    assert!(!after.news());
}

/// A login key whose name holds another key in the protected keychain (the profile
/// re-keyed off it) is never copied back beside it, so no start rewrites anything.
#[test]
fn a_login_key_a_profile_moved_off_is_never_copied_back() {
    mac();
    let r = root("rekeyed-off");
    let slot = profile_slot_name(&r);
    plant(Store::Keys, &slot, &[0x38; 32]);
    old_build_writes(&slot, &[0x39; 32]);
    let _ = take_writes();
    for _ in 0..2 {
        let moved = settle_move(&r);
        assert_eq!((moved.left, moved.wrote, moved.held), (1, 0, 0), "{moved:?}");
        assert!(!moved.news());
    }
    assert_eq!(take_writes(), 0);
    assert_eq!(names_in(Store::Keys), vec![slot]);
}

/// A wipe forgets a staged re-key key with the slot.
#[test]
fn a_wipe_forgets_a_staged_rekey_key() {
    mac();
    let tmp = crate::test_tmp::tempdir().unwrap();
    plant(Store::Keys, &rekey_slot_name(tmp.path()), &[0x3a; 32]);
    plant(Store::AppId, &rekey_slot_name(tmp.path()), &[0x3a; 32]);
    forget_key_at(tmp.path(), None);
    assert!(names_in(Store::Keys).is_empty() && names_in(Store::AppId).is_empty());
}

/// A staged key opens the identity right after the profile slot, before any
/// login item is read.
#[test]
fn an_unlock_tries_a_staged_key_before_the_login_keychain() {
    mac();
    let r = root("staged-first");
    plant(Store::Keys, &rekey_slot_name(&r), &[0x3b; 32]);
    old_build_writes(&profile_slot_name(&r), &[0x3c; 32]);
    let _ = take_reads();
    assert_eq!(key_that_opens(&r, &sealed(7, &[0x3b; 32])), Some((Source::Rekey, [0x3b; 32])));
    assert!(take_reads().iter().all(|(s, _)| *s != Store::Legacy), "the login keychain was read first");
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

/// Prompts stay off until the OUTERMOST quiet call ends: the system switch turns them
/// back on when any holder lets go, so a nested call (a write inside the re-key) must
/// not. A process setting only: no keychain item is read or written.
#[cfg(target_os = "macos")]
#[test]
fn a_nested_quiet_call_keeps_prompts_off_until_the_outer_one_ends() {
    use security_framework::os::macos::keychain::SecKeychain;
    without_prompts(|| {
        without_prompts(|| ());
        assert!(!SecKeychain::user_interaction_allowed().unwrap(), "a nested quiet call turned prompts back on");
    });
}

/// After a re-key the old key leaves only where no file needs it: this root's
/// profile slot in another group and its copies always, the machine slot only for a
/// key proven to have been this root's that no login item mirrors.
#[test]
fn a_retired_key_leaves_only_where_no_file_needs_it() {
    let (new, old, other) = ([0xa1u8; 32], [0xa2u8; 32], [0xa3u8; 32]);
    let needs_new = |v: &[u8]| v == new;
    let retired = [zeroize::Zeroizing::new(old)];
    use_mac_layout(Some(true));
    reset_fakes();
    let r = root("retire");
    plant(Store::Keys, &profile_slot_name(&r), &new);
    plant(Store::AppId, &profile_slot_name(&r), &old);
    plant(Store::Keys, &machine_slot_name(), &old);
    plant(Store::AppId, &machine_slot_name(), &other);
    plant(Store::Keys, &copy_name(&profile_slot_name(&r), &old), &old);
    assert_eq!(retire(&r, &retired, &needs_new), 0);
    assert_eq!(held(Store::Keys, &profile_slot_name(&r)), Some(new.to_vec()), "the promoted key went");
    assert_eq!(held(Store::AppId, &profile_slot_name(&r)), None, "the other group kept the old key");
    assert_eq!(held(Store::Keys, &machine_slot_name()), None, "the machine slot kept the old key");
    assert_eq!(held(Store::AppId, &machine_slot_name()), Some(other.to_vec()), "another identity's machine key went");
    assert!(names_in(Store::Keys).iter().all(|n| !n.contains(COPY_MARK)), "a copy stayed");

    for (mirrored, needed) in [(true, false), (false, true)] {
        reset_fakes();
        plant(Store::Keys, &machine_slot_name(), &old);
        if mirrored {
            old_build_writes(&machine_slot_name(), &old);
            inject(Fault::LegacyNotOwner);
        }
        let _ = retire(&r, &retired, &|v: &[u8]| v == new || (needed && v == old));
        clear_faults();
        assert_eq!(held(Store::Keys, &machine_slot_name()), Some(old.to_vec()), "mirrored {mirrored}, needed {needed}");
    }
    reset_fakes();
    plant(Store::AppId, &profile_slot_name(&r), &old);
    let _ = retire(&r, &[], &|v: &[u8]| v == old);
    assert_eq!(held(Store::AppId, &profile_slot_name(&r)), Some(old.to_vec()), "a key a file needs left the profile slot");
}

/// The move's file-keychain half against the real login keychain, in the test
/// service only, on items this test writes the way 0.13 did. Where no login keychain
/// is usable without asking (an ssh session) these FAIL, never pass on nothing;
/// `HOLLOW_SKIP_LOGIN_KEYCHAIN=1` skips them knowingly. They prove the file-keychain
/// calls only: the protected half needs the signed build (`scripts/macos_keychain_check.sh`).
#[cfg(target_os = "macos")]
mod file_keychain {
    use super::*;
    use security_framework::os::macos::keychain::SecKeychain;
    use security_framework::passwords::{delete_generic_password, get_generic_password, set_generic_password};

    const SERVICE: &str = "com.hollow.test.identity";
    /// The test that plays the other process, by its full name.
    const OTHER: &str = "identity::platform_keystore::tests::file_keychain::other_process";
    const JOB: &str = "HOLLOW_KEYCHAIN_TEST_JOB";
    /// The cross-process rewrite runs in a process of its own: afterwards that
    /// process's view of the login keychain is stale (a listing misses new items).
    const SCENARIO: &str = "identity::platform_keystore::tests::file_keychain::rewritten_in_another_process";
    const SCENARIO_JOB: &str = "HOLLOW_KEYCHAIN_TEST_SCENARIO";
    /// The test that plays a process which makes a login item and stays alive until
    /// told to delete it: only an item's maker may delete it.
    const CREATOR: &str = "identity::platform_keystore::tests::file_keychain::creator_process";
    const CREATOR_JOB: &str = "HOLLOW_KEYCHAIN_TEST_CREATOR";
    const READY: &str = "HOLLOW-KEYCHAIN-READY";
    /// Set for a run whose items the leak check counts: every item name carries it.
    const RUN: &str = "HOLLOW_KEYCHAIN_RUN";
    const MODULE: &str = "identity::platform_keystore::tests::file_keychain::";
    const REKEYED: &str = "identity::platform_keystore::tests::file_keychain::rekeyed_in_a_process_of_its_own";
    const REKEYED_JOB: &str = "HOLLOW_KEYCHAIN_TEST_REKEYED";

    /// 8 hex chars: this run's tag, or a fresh one.
    fn run_tag() -> String {
        std::env::var(RUN).ok().filter(|t| t.len() == 8 && is_hex16(&format!("{t}{t}"))).unwrap_or_else(|| {
            let mut tag = [0u8; 4];
            getrandom::fill(&mut tag).expect("random");
            hex::encode(tag)
        })
    }

    /// A process of this test binary that made a login item and keeps it until
    /// dropped, then deletes it itself.
    struct Creator {
        child: std::process::Child,
        out: std::io::BufReader<std::process::ChildStdout>,
    }

    impl Creator {
        /// `job` is `create` (a new item) or `rewrite` (delete, then add).
        fn spawn(job: &str, name: &str, byte: u8) -> Self {
            Self::spawn_from(&std::env::current_exe().expect("the test binary"), job, name, byte)
        }

        fn spawn_from(exe: &std::path::Path, job: &str, name: &str, byte: u8) -> Self {
            use std::io::BufRead;
            let mut child = std::process::Command::new(exe)
                .args([CREATOR, "--exact", "--ignored", "--test-threads=1", "--nocapture"])
                .env(CREATOR_JOB, format!("{job}:{name}:{byte}"))
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .spawn()
                .expect("a creator process");
            let mut out = std::io::BufReader::new(child.stdout.take().expect("its stdout"));
            let mut line = String::new();
            loop {
                line.clear();
                let read = out.read_line(&mut line).expect("the creator's output");
                assert!(read > 0, "the creator ({job}) ended before its item was made");
                if line.contains(READY) {
                    break;
                }
            }
            Self { child, out }
        }
    }

    /// The item's maker as another program: a copy of this test binary at another
    /// path. The login keychain lets this binary read what the copy made (the same
    /// code) but not delete it (another app), as 0.13's item stands to 0.14 in the
    /// field. The copy deletes it itself when dropped.
    struct OtherApp {
        _maker: Creator,
        _dir: crate::test_tmp::TestDir,
    }

    impl OtherApp {
        fn spawn(name: &str, byte: u8) -> Self {
            let dir = crate::test_tmp::tempdir().unwrap();
            let copy = dir.path().join("other_app");
            std::fs::copy(std::env::current_exe().expect("the test binary"), &copy).expect("a copy of the test binary");
            Self { _maker: Creator::spawn_from(&copy, "create", name, byte), _dir: dir }
        }
    }

    impl Drop for Creator {
        fn drop(&mut self) {
            use std::io::Read;
            drop(self.child.stdin.take());
            let status = self.child.wait();
            let mut rest = String::new();
            let _ = self.out.read_to_string(&mut rest);
            if !std::thread::panicking() {
                assert!(status.is_ok_and(|s| s.success()) && rest.contains("1 passed"), "the creator failed: {rest}");
            }
        }
    }

    /// Runs the ignored test `test` in a new process of this test binary.
    fn in_new_process(test: &str, key: &str, job: &str) {
        let out = std::process::Command::new(std::env::current_exe().expect("the test binary"))
            .args([test, "--exact", "--ignored", "--test-threads=1"])
            .env(key, job)
            .output()
            .expect("a new process");
        let said = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success() && said.contains("1 passed"), "the new process ({job}) failed: {said}");
    }

    /// One 0.13-style item under a fresh slot name, deleted on drop.
    struct Planted(String);

    impl Planted {
        fn new(value: &[u8]) -> Option<Self> {
            let mut tag = [0u8; 8];
            getrandom::fill(&mut tag).expect("random");
            let name = format!("{MAC_BASE}.{}{}", run_tag(), hex::encode(&tag[..4]));
            match without_prompts(|| set_generic_password(SERVICE, &name, value)) {
                Ok(()) => Some(Self(name)),
                Err(_) if std::env::var("HOLLOW_SKIP_LOGIN_KEYCHAIN").as_deref() == Ok("1") => None,
                Err(e) => panic!(
                    "no login keychain usable without asking ({}); run from a desktop session, or set HOLLOW_SKIP_LOGIN_KEYCHAIN=1 to skip",
                    e.code()
                ),
            }
        }

        fn now(&self) -> Option<Vec<u8>> {
            without_prompts(|| get_generic_password(SERVICE, &self.0)).ok()
        }

        /// What 0.13 did on every store: delete, then add a new item.
        fn rewrite(&self, value: &[u8]) {
            without_prompts(|| {
                let _ = delete_generic_password(SERVICE, &self.0);
                set_generic_password(SERVICE, &self.0, value).expect("rewrite");
            });
        }

        /// Runs `job` on this item in a new process of this test binary.
        fn in_other_process(&self, job: &str, byte: u8) {
            in_new_process(OTHER, JOB, &format!("{job}:{}:{byte}", self.0));
        }
    }

    impl Drop for Planted {
        fn drop(&mut self) {
            let _ = without_prompts(|| delete_generic_password(SERVICE, &self.0));
        }
    }

    /// The other process of the cross-process tests; does nothing unless one spawned it.
    #[test]
    #[ignore = "run only by the cross-process tests, as another process"]
    fn other_process() {
        let Ok(job) = std::env::var(JOB) else { return };
        let mut parts = job.splitn(3, ':');
        let (Some(what), Some(name), Some(byte)) = (parts.next(), parts.next(), parts.next()) else { panic!("job {job}") };
        assert!(name.starts_with(MAC_BASE) && SERVICE.contains(".test."));
        let byte: u8 = byte.parse().expect("byte");
        let _quiet = SecKeychain::disable_user_interaction().ok();
        match what {
            // An existing item: the add answers duplicate and the call updates it in place.
            "update" => set_generic_password(SERVICE, name, &[byte; 32]).expect("update"),
            "holds" => assert_eq!(get_generic_password(SERVICE, name).ok(), Some(vec![byte; 32]), "a new process reads"),
            "gone" => assert!(get_generic_password(SERVICE, name).is_err(), "a new process still reads the item"),
            // A process that made no item can still delete one by name: this one's view
            // of the login keychain is fresh, where the planting process's may be stale.
            "none_left" => {
                let _real = RealKeystore::enter_file_keychain();
                let left: Vec<String> = without_prompts(|| list(Store::Legacy, "")).into_iter().filter(|n| n.contains(&name[MAC_BASE.len() + 1..])).collect();
                assert!(left.is_empty(), "the login keychain tests left {} item(s): {left:?}", left.len());
            }
            "delete" => {
                let _ = delete_generic_password(SERVICE, name);
                assert!(get_generic_password(SERVICE, name).is_err(), "a new process could not delete the item");
            }
            other => panic!("job {other}"),
        }
    }

    /// The creator process: makes its item, says so, waits for its parent to close
    /// stdin, then deletes the item it made (an item its parent made stays for it).
    #[test]
    #[ignore = "run only by Creator, as the process that makes a login item"]
    fn creator_process() {
        use std::io::{Read, Write};
        let Ok(job) = std::env::var(CREATOR_JOB) else { return };
        let mut parts = job.splitn(3, ':');
        let (Some(what), Some(name), Some(byte)) = (parts.next(), parts.next(), parts.next()) else { panic!("job {job}") };
        assert!(name.starts_with(MAC_BASE) && SERVICE.contains(".test."));
        let byte: u8 = byte.parse().expect("byte");
        let _quiet = SecKeychain::disable_user_interaction().ok();
        if what == "rewrite" {
            let _ = delete_generic_password(SERVICE, name);
        }
        assert!(matches!(what, "create" | "rewrite"), "job {what}");
        set_generic_password(SERVICE, name, &[byte; 32]).expect("make the item");
        let mut out = std::io::stdout();
        let _ = writeln!(out, "{READY}");
        let _ = out.flush();
        let _ = std::io::stdin().read_to_end(&mut Vec::new());
        let _ = delete_generic_password(SERVICE, name);
    }

    /// The field case on this Mac's real login keychain (test service): another
    /// program made the item, so this one's delete is refused (`errSecInvalidOwnerEdit`),
    /// and after the re-key the key it holds opens neither file while the profile's
    /// new key opens both; a second start does nothing. The protected stores are fake
    /// (an unsigned test binary is refused them).
    #[test]
    fn a_login_item_another_process_made_opens_nothing_after_the_rekey() {
        let Some(usable) = Planted::new(&[0x52; 32]) else { return };
        drop(usable);
        // In a process of its own: once another program deleted an item this process
        // read, this process's view of the login keychain can go stale.
        in_new_process(REKEYED, REKEYED_JOB, "rekey");
    }

    #[test]
    #[ignore = "run only by a_login_item_another_process_made_opens_nothing_after_the_rekey, in a process of its own"]
    fn rekeyed_in_a_process_of_its_own() {
        use crate::identity::keychain_rekey::{self, Rekey};
        if std::env::var(REKEYED_JOB).is_err() {
            return;
        }
        let base: &'static str = Box::leak(format!("{MAC_BASE}_t{}", run_tag()).into_boxed_str());
        set_base(Some(base));
        let _real = RealKeystore::enter_login_only();
        use_mac_layout(Some(true));
        let tmp = crate::test_tmp::tempdir().unwrap();
        let dir = tmp.path();
        let old = [0x53u8; 32];
        std::fs::write(dir.join("identity.key"), sealed(8, &old)).unwrap();
        std::fs::write(dir.join("identity.device"), sealed(9, &old)).unwrap();
        let name = profile_slot_name(dir);
        let creator = OtherApp::spawn(&name, 0x53);
        assert_eq!(without_prompts(|| read(Store::Legacy, &name)), Ok(Some(old.to_vec())), "this process cannot read the item");

        let start = || {
            let ours = keychain_rekey::Ours::of(&[dir.to_path_buf()]);
            (settle_move_judged(dir, &|k| ours.opened_by(k)), keychain_rekey::settle(dir))
        };
        let (moved, rekey) = start();
        assert_eq!((moved.held, moved.moved), (1, 0), "the delete of another process's item was not refused: {moved:?}");
        assert_eq!(rekey, Rekey::Rekeyed { stay: 1 });
        assert_eq!(without_prompts(|| read(Store::Legacy, &name)), Ok(Some(old.to_vec())), "the login item changed");
        let open_with = |key: &[u8; 32], file: &str| {
            crate::identity::encryption::decrypt_identity(&std::fs::read(dir.join(file)).unwrap(), key).is_ok()
        };
        assert!(!open_with(&old, "identity.key") && !open_with(&old, "identity.device"), "the login key still opens a file");
        let new = <[u8; 32]>::try_from(profile_value(dir).expect("a profile key").as_slice()).unwrap();
        assert!(open_with(&new, "identity.key") && open_with(&new, "identity.device"));
        let (moved, rekey) = start();
        assert!(!moved.news() && rekey == Rekey::Nothing, "the second start found work: {moved:?} {rekey:?}");

        drop(creator);
        assert_eq!(without_prompts(|| read(Store::Legacy, &name)), Ok(None), "the creator left its item");
        set_base(None);
    }

    /// Every login keychain test, run once more in a process of its own with a run
    /// tag in every item name, leaves no item of that run behind: each process deletes
    /// what it made (only an item's maker may).
    #[test]
    fn the_login_keychain_tests_leave_no_item_behind() {
        if std::env::var(RUN).is_ok() {
            return;
        }
        let Some(usable) = Planted::new(&[0x54; 32]) else { return };
        drop(usable);
        let tag = run_tag();
        let out = std::process::Command::new(std::env::current_exe().expect("the test binary"))
            .args([MODULE, "--test-threads=1"])
            .env(RUN, &tag)
            .output()
            .expect("the suite in a new process");
        let said = String::from_utf8_lossy(&out.stdout);
        assert!(out.status.success() && said.contains(" passed;"), "the suite failed in its own process: {said}");
        // A fresh process lists: this one's view can miss items other processes made.
        in_new_process(OTHER, JOB, &format!("none_left:{MAC_BASE}.{tag}:0"));
    }

    #[test]
    fn the_test_service_is_not_the_real_one() {
        assert!(SERVICE.contains(".test."));
    }

    /// Without the flag set false, a signed build's query for the login keychain can
    /// answer with the protected copy, and a delete can take it. This checks the
    /// query only; the signed run checks what the keychain does with it.
    #[test]
    fn a_file_keychain_query_never_reaches_the_protected_keychain() {
        assert_eq!(mac::file_query_flag(), Some(false));
    }

    #[test]
    fn the_real_file_keychain_item_a_move_read_is_really_deleted() {
        let _real = RealKeystore::enter_file_keychain();
        let Some(planted) = Planted::new(&[0x4a; 32]) else { return };
        let (value, item) = without_prompts(|| read_ref(Store::Legacy, &planted.0)).unwrap().expect("the planted item reads");
        assert_eq!(value, vec![0x4a; 32]);
        assert!(matches!(item, Item::Object(_)), "a file-based read handed back a persistent reference");
        assert_eq!(without_prompts(|| take_source(Store::Legacy, &planted.0, &value, &item, true)), Outcome::Moved);
        assert_eq!(planted.now(), None, "the login keychain item is still there");
        planted.in_other_process("gone", 0);
    }

    /// A persistent reference to a file-based item finds whatever holds its name, so
    /// a delete by one took the key 0.13 wrote after the read.
    #[test]
    fn the_real_file_keychain_item_rewritten_after_the_read_stays() {
        let _real = RealKeystore::enter_file_keychain();
        let Some(planted) = Planted::new(&[0x4b; 32]) else { return };
        let (value, item) = without_prompts(|| read_ref(Store::Legacy, &planted.0)).unwrap().expect("the planted item reads");
        planted.rewrite(&[0x4c; 32]);
        assert_eq!(without_prompts(|| take_source(Store::Legacy, &planted.0, &value, &item, true)), Outcome::Kept);
        assert_eq!(planted.now(), Some(vec![0x4c; 32]), "the key written after the read was deleted");
    }

    /// 0.13 in another process rewrites the item between the read and the delete,
    /// by delete+add and by an in-place update. This process's read can miss the new
    /// key afterwards, so the move must never count it as moved, and a new process
    /// must still read the new key.
    #[test]
    fn a_login_item_another_process_rewrote_after_the_read_stays() {
        let Some(usable) = Planted::new(&[0x4e; 32]) else { return };
        drop(usable);
        for job in ["rewrite", "update"] {
            in_new_process(SCENARIO, SCENARIO_JOB, job);
        }
    }

    #[test]
    #[ignore = "run only by a_login_item_another_process_rewrote_after_the_read_stays, in a process of its own"]
    fn rewritten_in_another_process() {
        let Ok(job) = std::env::var(SCENARIO_JOB) else { return };
        let _real = RealKeystore::enter_file_keychain();
        let planted = Planted::new(&[0x4e; 32]).expect("the login keychain");
        let (value, item) = without_prompts(|| read_ref(Store::Legacy, &planted.0)).unwrap().expect("the planted item reads");
        // A rewrite makes an item only the rewriting process may delete: it stays
        // alive until the checks are done, then deletes it itself.
        let rewriter = (job == "rewrite").then(|| Creator::spawn("rewrite", &planted.0, 0x4f));
        if rewriter.is_none() {
            planted.in_other_process(&job, 0x4f);
        }
        let outcome = without_prompts(|| take_source(Store::Legacy, &planted.0, &value, &item, true));
        assert_eq!(outcome, Outcome::Kept, "{job}: a login item another process rewrote was counted as {outcome:?}");
        planted.in_other_process("holds", 0x4f);
        drop(rewriter);
        // This process's view may miss the item now, so a delete by name here can
        // find nothing and leave it: a fresh process deletes it.
        planted.in_other_process("delete", 0);
    }

    /// The file-based keychain deletes by the item object alone and ignores the name
    /// beside it (macOS 26): the object decides which item goes, so it must be the one
    /// the read returned, and a delete by name would take another item.
    #[test]
    fn a_file_keychain_delete_takes_exactly_the_item_object() {
        let _real = RealKeystore::enter_file_keychain();
        let Some(a) = Planted::new(&[0x50; 32]) else { return };
        let Some(b) = Planted::new(&[0x51; 32]) else { return };
        let (_, item) = without_prompts(|| read_ref(Store::Legacy, &a.0)).unwrap().expect("the planted item reads");
        assert_eq!(without_prompts(|| delete_item(Store::Legacy, &b.0, &item)), Ok(Deleted::Took));
        assert_eq!(a.now(), None, "the item the object names stayed");
        assert_eq!(b.now(), Some(vec![0x51; 32]), "a delete by an item object took another item by its name");
    }

    /// The file-keychain half alone: a listing and a read of the test service see
    /// exactly the planted item, and a delete by name takes it.
    #[test]
    fn the_real_file_keychain_lists_reads_and_forgets_in_the_test_service() {
        let _real = RealKeystore::enter_file_keychain();
        let Some(planted) = Planted::new(&[0x4d; 32]) else { return };
        assert!(without_prompts(|| list(Store::Legacy, MAC_BASE)).contains(&planted.0));
        assert_eq!(without_prompts(|| read(Store::Legacy, &planted.0)), Ok(Some(vec![0x4d; 32])));
        without_prompts(|| delete(Store::Legacy, &planted.0)).unwrap();
        assert_eq!(planted.now(), None);
    }
}
