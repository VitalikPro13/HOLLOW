//! G1 scale probe, MLS alone: what one server group costs at 1k, 10k and 100k leaves
//! with our ciphersuite, bound `hl1` device credentials and leaf extensions, through the
//! real `MlsManager`. Ignored; one command per run:
//!   HOLLOW_MLS_SIZES=1000,10000 HOLLOW_MLS_OUT=/path/mls.csv \
//!   cargo test --lib mls_scale_probe -- --ignored --nocapture

use std::time::Instant;

use super::MlsManager;
use crate::identity::native_identity::NativeKeypair;

const GROUP: &str = "g1-scale-probe-server";

/// A distinct, reproducible key for every index (the harness tags stop at 255).
fn key(domain: u8, index: u32) -> NativeKeypair {
    let mut secret = [0u8; 32];
    secret[0] = domain;
    secret[1..5].copy_from_slice(&index.to_be_bytes());
    for (i, slot) in secret.iter_mut().enumerate().skip(5) {
        *slot = (i as u8).wrapping_mul(29).wrapping_add(domain).wrapping_add(index as u8);
    }
    NativeKeypair::from_secret_bytes(&secret)
}

/// One member's device, bound to its own master, and the KeyPackage a join would send.
fn member_key_package(index: u32) -> (String, Vec<u8>) {
    let device = key(2, index);
    let master = key(1, index);
    let mgr = MlsManager::new(&device, &master).expect("member manager");
    let kp = mgr.generate_key_package_for(GROUP, true).expect("member key package");
    (device.peer_id(), kp)
}

fn base64_len(n: usize) -> usize {
    n.div_ceil(3) * 4
}

fn env_sizes() -> Vec<usize> {
    let mut v: Vec<usize> = std::env::var("HOLLOW_MLS_SIZES")
        .ok()
        .map(|s| s.split(',').filter_map(|x| x.trim().parse().ok()).collect())
        .filter(|v: &Vec<usize>| !v.is_empty())
        .unwrap_or_else(|| vec![1000, 10_000]);
    v.sort_unstable();
    v.dedup();
    v
}

struct Row {
    leaves: usize,
    metric: &'static str,
    value: f64,
    unit: &'static str,
}

#[test]
#[ignore = "scale probe: builds MLS groups up to 100k leaves. Run with --ignored --nocapture."]
fn mls_scale_probe() {
    let sizes = env_sizes();
    let batch: usize = std::env::var("HOLLOW_MLS_BATCH").ok().and_then(|s| s.parse().ok()).unwrap_or(500);
    let out = std::env::var("HOLLOW_MLS_OUT").ok();
    println!("\n=== G1 MLS PROBE sizes={sizes:?} growth batch={batch} ===");

    let mut owner = MlsManager::new(&key(4, 0), &key(3, 0)).expect("owner");
    owner.create_group(GROUP).expect("create group");
    let mut next: u32 = 0;
    let mut rows: Vec<Row> = Vec::new();
    let started = Instant::now();
    let push = |rows: &mut Vec<Row>, leaves: usize, metric: &'static str, value: f64, unit: &'static str| {
        println!("[mls] leaves={leaves:>7} {metric:<34} {value:>14.3} {unit}");
        rows.push(Row { leaves, metric, value, unit });
    };

    for &target in &sizes {
        // Grow to target - 1 leaves with batched adds, the way a busy server's batch
        // timer would; then the measured joiner makes `target`.
        let grow = Instant::now();
        let mut kp_secs = 0.0;
        let mut commit_secs = 0.0;
        while owner.member_count(GROUP) < target - 1 {
            let n = batch.min(target - 1 - owner.member_count(GROUP));
            let t = Instant::now();
            let kps: Vec<(String, Vec<u8>)> = (0..n)
                .map(|_| {
                    next += 1;
                    member_key_package(next)
                })
                .collect();
            kp_secs += t.elapsed().as_secs_f64();
            let t = Instant::now();
            owner.add_members_batch(GROUP, &kps).expect("growth add");
            owner.merge_pending_commit(GROUP).expect("growth merge");
            commit_secs += t.elapsed().as_secs_f64();
        }
        println!(
            "[mls] grew to {} leaves in {:.1}s (key packages {kp_secs:.1}s, owner commits {commit_secs:.1}s)",
            owner.member_count(GROUP),
            grow.elapsed().as_secs_f64(),
        );

        // The measured joiner: a real bound member that will process everything after.
        let obs_index = 1_000_000 + target as u32;
        let (obs_device, obs_master) = (key(2, obs_index), key(1, obs_index));
        let mut observer = MlsManager::new(&obs_device, &obs_master).expect("observer");
        let obs_kp = observer.generate_key_package_for(GROUP, true).expect("observer kp");
        push(&mut rows, target, "key_package_bytes", obs_kp.len() as f64, "B");

        let t = Instant::now();
        let (commit, welcome, _) = owner
            .add_members_batch(GROUP, &[(obs_device.peer_id(), obs_kp)])
            .expect("add the observer");
        owner.merge_pending_commit(GROUP).expect("merge observer add");
        push(&mut rows, target, "add1_commit_build_secs", t.elapsed().as_secs_f64(), "s");
        push(&mut rows, target, "add1_commit_bytes", commit.len() as f64, "B");
        push(&mut rows, target, "add1_welcome_bytes", welcome.len() as f64, "B");
        push(&mut rows, target, "add1_welcome_base64_bytes", base64_len(welcome.len()) as f64, "B");
        push(
            &mut rows,
            target,
            "welcome_share_of_64MiB_payload",
            base64_len(welcome.len()) as f64 / (64.0 * 1024.0 * 1024.0),
            "ratio",
        );

        let t = Instant::now();
        observer.join_from_welcome(GROUP, &welcome).expect("observer joins");
        push(&mut rows, target, "welcome_process_secs", t.elapsed().as_secs_f64(), "s");
        assert_eq!(observer.member_count(GROUP), owner.member_count(GROUP), "observer sees the whole group");

        // A batched add of 50 (a busy batch tick).
        let kps: Vec<(String, Vec<u8>)> = (0..50)
            .map(|_| {
                next += 1;
                member_key_package(next)
            })
            .collect();
        let t = Instant::now();
        let (commit, welcome, _) = owner.add_members_batch(GROUP, &kps).expect("add 50");
        owner.merge_pending_commit(GROUP).expect("merge add 50");
        push(&mut rows, target, "add50_commit_build_secs", t.elapsed().as_secs_f64(), "s");
        push(&mut rows, target, "add50_commit_bytes", commit.len() as f64, "B");
        push(&mut rows, target, "add50_welcome_bytes", welcome.len() as f64, "B");
        let t = Instant::now();
        observer.process_commit(GROUP, &commit).expect("observer processes add 50");
        push(&mut rows, target, "add50_commit_process_secs", t.elapsed().as_secs_f64(), "s");

        // One add on its own, processed by a member.
        next += 1;
        let one = member_key_package(next);
        let removed_device = one.0.clone();
        let (commit, _, _) = owner.add_members_batch(GROUP, &[one]).expect("add 1");
        owner.merge_pending_commit(GROUP).expect("merge add 1");
        let t = Instant::now();
        observer.process_commit(GROUP, &commit).expect("observer processes add 1");
        push(&mut rows, target, "add1_commit_process_secs", t.elapsed().as_secs_f64(), "s");

        // Two removes in a row by the owner: a remove carries an update path, whose
        // size follows how many tree nodes are blank.
        for (metric_build, metric_bytes, metric_proc) in [
            ("remove1_commit_build_secs", "remove1_commit_bytes", "remove1_commit_process_secs"),
            ("remove2_commit_build_secs", "remove2_commit_bytes", "remove2_commit_process_secs"),
        ] {
            let victim = if metric_build.starts_with("remove1") {
                removed_device.clone()
            } else {
                kps[0].0.clone()
            };
            let t = Instant::now();
            let commit = owner.remove_member(GROUP, &victim).expect("remove");
            owner.merge_pending_commit(GROUP).expect("merge remove");
            push(&mut rows, target, metric_build, t.elapsed().as_secs_f64(), "s");
            push(&mut rows, target, metric_bytes, commit.len() as f64, "B");
            let t = Instant::now();
            observer.process_commit(GROUP, &commit).expect("observer processes remove");
            push(&mut rows, target, metric_proc, t.elapsed().as_secs_f64(), "s");
        }

        // An application message, both ends.
        let plaintext = vec![b'x'; 512];
        let t = Instant::now();
        let ct = owner.encrypt(GROUP, &plaintext).expect("encrypt");
        push(&mut rows, target, "app_msg_encrypt_secs", t.elapsed().as_secs_f64(), "s");
        push(&mut rows, target, "app_msg_512B_ciphertext_bytes", ct.len() as f64, "B");
        let t = Instant::now();
        observer.decrypt(GROUP, &ct).expect("decrypt");
        push(&mut rows, target, "app_msg_decrypt_secs", t.elapsed().as_secs_f64(), "s");

        // What each member keeps (the persisted MLS blob).
        push(&mut rows, target, "member_state_bytes", observer.serialize_storage().expect("observer state").len() as f64, "B");
        push(&mut rows, target, "owner_state_bytes", owner.serialize_storage().expect("owner state").len() as f64, "B");
        push(&mut rows, target, "elapsed_total_secs", started.elapsed().as_secs_f64(), "s");
    }

    if let Some(path) = out {
        let mut csv = String::from("leaves,metric,value,unit\n");
        for r in &rows {
            csv.push_str(&format!("{},{},{},{}\n", r.leaves, r.metric, r.value, r.unit));
        }
        std::fs::write(&path, csv).expect("write mls csv");
        println!("[mls] csv written to {path}");
    }
    println!("=== G1 MLS PROBE END ===\n");
}

/// Why an application message costs more as the group grows: the same group built on
/// bare OpenMLS (no Hollow wrapper), timed with our `max_past_epochs` (3) and with
/// none, so the cost can be split between the wrapper, past-epoch state and OpenMLS.
///   HOLLOW_MLS_SIZES=1000,10000 cargo test --lib mls_scale_probe_message_cost -- --ignored --nocapture
#[test]
#[ignore = "scale probe: bare OpenMLS message cost by group size. Run with --ignored --nocapture."]
fn mls_scale_probe_message_cost() {
    use openmls::prelude::*;
    use openmls_basic_credential::SignatureKeyPair;
    use openmls_rust_crypto::OpenMlsRustCrypto;

    let cs = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
    let identity = |provider: &OpenMlsRustCrypto, name: String| {
        let signer = SignatureKeyPair::new(cs.signature_algorithm()).expect("signer");
        let _ = provider;
        let cred = CredentialWithKey {
            credential: BasicCredential::new(name.into_bytes()).into(),
            signature_key: signer.to_public_vec().into(),
        };
        (signer, cred)
    };
    // 200 bytes is the length of a bound `hl1:{device}:{master}:{sig}` credential.
    for &size in &env_sizes() {
        for (past, cred_len) in [(0usize, 8usize), (3, 8), (0, 200), (3, 200)] {
            let provider = OpenMlsRustCrypto::default();
            let (signer, cred) = identity(&provider, "owner".into());
            let config = MlsGroupCreateConfig::builder()
                .ciphersuite(cs)
                .use_ratchet_tree_extension(true)
                .max_past_epochs(past)
                .build();
            let mut group = MlsGroup::new(&provider, &signer, &config, cred).expect("group");
            let members = OpenMlsRustCrypto::default();
            let mut added = 1usize;
            while added < size {
                let n = 500.min(size - added);
                let kps: Vec<KeyPackage> = (0..n)
                    .map(|i| {
                        let (s, c) = identity(&members, format!("{:0>cred_len$}", added + i));
                        KeyPackage::builder().build(cs, &members, &s, c).expect("kp").key_package().clone()
                    })
                    .collect();
                group.add_members(&provider, &signer, &kps).expect("add");
                group.merge_pending_commit(&provider).expect("merge");
                added += n;
            }
            // A few commits past the build, so past-epoch state is as full as it gets.
            let t = Instant::now();
            let rounds = 5;
            for _ in 0..rounds {
                group.create_message(&provider, &signer, &[b'x'; 512]).expect("message");
            }
            let per_msg = t.elapsed().as_secs_f64() / rounds as f64;
            let stored: usize = provider.storage().values.read().expect("storage").values().map(Vec::len).sum();
            println!(
                "[mls-raw] leaves={size:>7} max_past_epochs={past} credential_bytes={cred_len} create_message={per_msg:.4}s storage_bytes={stored}",
            );
        }
    }
}
