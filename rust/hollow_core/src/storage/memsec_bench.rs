//! TEST-ONLY: what SQLCipher's `cipher_memory_security` costs the hot store paths
//! (HOL-SEC-201 measurement). The pragma is process-wide and cannot be turned off, so
//! each mode runs in its own process:
//! `HOLLOW_MEMSEC_BENCH_OUT=<file> [HOLLOW_MEMSEC=1] cargo test --lib memsec_bench -- --ignored`

use std::time::Instant;

use super::MessageStore;
use crate::crdt::hlc::HlcTimestamp;
use crate::crdt::operations::{CrdtOp, CrdtPayload};

const KEY: &str = "5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e";
const ROUNDS: usize = 5;

/// The median of `ROUNDS` timings of `run`, in milliseconds per `per` units.
fn median_ms(per: usize, mut run: impl FnMut(usize)) -> f64 {
    run(usize::MAX);
    let mut times: Vec<f64> = (0..ROUNDS)
        .map(|round| {
            let t = Instant::now();
            run(round);
            t.elapsed().as_secs_f64() * 1000.0 / per as f64
        })
        .collect();
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    times[ROUNDS / 2]
}

fn op(i: usize) -> CrdtOp {
    CrdtOp {
        server_id: "b".repeat(40),
        hlc: HlcTimestamp { physical_ms: 1_700_000_000_000 + i as u64, counter: 0, actor: "a".repeat(52) },
        author: "a".repeat(52),
        payload: CrdtPayload::ChannelRenamed { channel_id: format!("ch-{}", i % 7), new_name: "x".repeat(40) },
        auth: None,
        dev: None,
    }
}

#[test]
#[ignore = "measurement, run by hand"]
fn memsec_bench() {
    let Ok(out) = std::env::var("HOLLOW_MEMSEC_BENCH_OUT") else { return };
    let on = std::env::var("HOLLOW_MEMSEC").is_ok_and(|v| v == "1");
    let tmp = crate::test_tmp::tempdir().unwrap();
    let path = tmp.path().join("bench.db").to_string_lossy().into_owned();
    let store = MessageStore::open(&path, KEY).unwrap();
    let probe = rusqlite::Connection::open(&path).unwrap();
    probe.execute_batch(&format!("PRAGMA key = \"x'{KEY}'\";")).unwrap();
    if on {
        probe.execute_batch("PRAGMA cipher_memory_security = ON;").unwrap();
    }
    let state: String = probe.query_row("PRAGMA cipher_memory_security", [], |r| r.get(0)).unwrap();
    assert_eq!(state == "1", on, "cipher_memory_security reads {state}");

    let text = "m".repeat(200);
    let sig = "s".repeat(88);
    let mut next = 0usize;
    let mut insert_batch = |n: usize| {
        store.begin_transaction().unwrap();
        for _ in 0..n {
            next += 1;
            let mid = format!("{next:032x}");
            store
                .insert_channel_message("srv", "general", "sender", &text, false, 1_700_000_000_000 + next as i64, Some(&sig), Some("pk"), Some(&mid), None, None, None, None)
                .unwrap();
        }
        store.commit_transaction().unwrap();
    };
    let insert = median_ms(1, |_| insert_batch(500));
    for _ in 0..10 {
        insert_batch(500);
    }
    let page = median_ms(200, |_| {
        for _ in 0..200 {
            assert_eq!(store.load_channel_messages("srv", "general", 50).unwrap().len(), 50);
        }
    });
    let state_json = format!("{{\"blob\":\"{}\"}}", "c".repeat(100_000));
    let mut op_at = 0usize;
    let crdt = median_ms(1, |_| {
        store.begin_transaction().unwrap();
        for _ in 0..100 {
            op_at += 1;
            store.insert_crdt_op(&op(op_at)).unwrap();
        }
        store.save_server_state("srv", &state_json).unwrap();
        store.commit_transaction().unwrap();
    });
    let pickle = "p".repeat(3000);
    let mut sends = 0i64;
    let olm = median_ms(200, |_| {
        for _ in 0..200 {
            sends += 1;
            store.save_olm_session("peer", &pickle, sends, 0).unwrap();
        }
    });
    let secrets = vec![7u8; 30_000];
    let mls = median_ms(200, |_| {
        for _ in 0..200 {
            let save = crate::crypto::mls_storage::MlsSave {
                signer: b"signer".to_vec().into(),
                rows: vec![(String::new(), b"MessageSecrets-row".to_vec(), Some(secrets.clone().into()))],
                ..Default::default()
            };
            store.save_mls_state(&save).unwrap();
        }
    });
    let line = format!(
        "{} {} insert_500_batch_ms={insert:.3} page_50_read_ms={page:.4} crdt_100op_100kb_state_ms={crdt:.3} olm_save_ms={olm:.4} mls_save_30kb_ms={mls:.4}\n",
        std::env::consts::OS,
        if on { "memsec=ON " } else { "memsec=OFF" },
    );
    use std::io::Write;
    std::fs::OpenOptions::new().create(true).append(true).open(out).unwrap().write_all(line.as_bytes()).unwrap();
}
