//! AR-28 review MED-1, pinned: one check never allocates past `Budget::PEER.max_alloc`,
//! counted by a global allocator (so it lives here, in its own test binary). Run with
//! `cargo test --test alloc_cap` in rust/hollow_core/fuzz.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};

#[allow(dead_code)]
#[path = "../../src/node/image_check.rs"]
mod image_check;

struct Counting;
static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        track(l.size());
        unsafe { System.alloc(l) }
    }
    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        track(l.size());
        unsafe { System.alloc_zeroed(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        LIVE.fetch_sub(l.size(), Relaxed);
        unsafe { System.dealloc(p, l) }
    }
}

fn track(n: usize) {
    let live = LIVE.fetch_add(n, Relaxed) + n;
    PEAK.fetch_max(live, Relaxed);
}

#[global_allocator]
static A: Counting = Counting;

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &b in data {
        crc ^= u32::from(b);
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

/// Peak bytes allocated while checking `bytes`, beyond what was live before.
fn peak_of(bytes: &[u8]) -> (bool, usize) {
    let base = LIVE.load(Relaxed);
    PEAK.store(base, Relaxed);
    let passed = image_check::check(bytes).is_ok();
    (passed, PEAK.load(Relaxed) - base)
}

#[test]
fn no_check_allocates_past_the_budget() {
    let cap = image_check::Budget::PEER.max_alloc as usize;

    // The review's big16.png in miniature: a 16-bit RGBA header of 7000x7000.
    let img = image::ImageBuffer::<image::Rgba<u16>, Vec<u16>>::from_pixel(8, 8, image::Rgba([1, 2, 3, 65535]));
    let mut png = Vec::new();
    image::DynamicImage::ImageRgba16(img)
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .unwrap();
    png[16..20].copy_from_slice(&7000u32.to_be_bytes());
    png[20..24].copy_from_slice(&7000u32.to_be_bytes());
    let crc = crc32(&png[12..29]);
    png[29..33].copy_from_slice(&crc.to_be_bytes());

    // A 4096 px animation canvas, the largest an animation may declare.
    let mut gif = Vec::new();
    {
        let mut enc = image::codecs::gif::GifEncoder::new(&mut gif);
        for i in 0..2u8 {
            let frame = image::RgbaImage::from_pixel(4096, 16, image::Rgba([i, 2, 3, 255]));
            enc.encode_frame(image::Frame::from_parts(frame, 0, 0, image::Delay::from_numer_denom_ms(10, 1))).unwrap();
        }
    }
    gif[6..8].copy_from_slice(&4096u16.to_le_bytes());
    gif[8..10].copy_from_slice(&4096u16.to_le_bytes());

    for (what, bytes) in [("16-bit 7000 px PNG", png), ("4096 px GIF canvas", gif)] {
        let (passed, peak) = peak_of(&bytes);
        assert!(peak <= cap, "{what}: peak {} MiB past the {} MiB budget (passed={passed})", peak >> 20, cap >> 20);
    }
}
