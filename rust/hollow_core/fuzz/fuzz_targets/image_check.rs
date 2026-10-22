//! Any bytes into the AR-28 image check: it must return, never panic or hang.
#![no_main]

use std::time::{Duration, Instant};

use libfuzzer_sys::fuzz_target;

#[allow(dead_code)]
#[path = "../../src/node/image_check.rs"]
mod image_check;

fuzz_target!(|data: &[u8]| {
    // A smaller budget than a peer's: the fuzzer's job is finding panics and
    // slow paths per input byte, not decoding 48 MP photos.
    let budget = image_check::Budget {
        max_still_pixels: 4_000_000,
        max_anim_pixels: 16_000_000,
        max_time: Duration::from_secs(10),
        ..image_check::Budget::PEER
    };
    let started = Instant::now();
    let _ = image_check::decode_all(data, &budget, started + budget.max_time);
    assert!(started.elapsed() < Duration::from_secs(20), "the check outlived its deadline");
});
