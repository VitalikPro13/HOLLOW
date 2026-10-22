//! A pure-Rust full decode of a peer's image before any native decoder sees it (AR-28).
//!
//! Flutter paints images with Skia's native codecs (libwebp, libpng, libjpeg-turbo),
//! so a peer's bytes that render without a tap must first decode completely here,
//! every frame, inside a pixel, frame and time budget. The bytes themselves are never
//! changed: rail blobs and attachments are content-addressed.
//!
//! Depends on `image` and std alone, so the fuzz target can compile this file as is.

use std::io::Cursor;
use std::time::{Duration, Instant};

use image::{AnimationDecoder, ImageDecoder};

/// Version of these rules. A stored verdict from another version is checked again.
pub(crate) const RULE: i64 = 1;

/// What one check may spend. [`Budget::PEER`] is the only one outside tests.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Budget {
    /// Largest file accepted at all.
    pub max_bytes: usize,
    /// Longest side of a still image.
    pub max_side: u32,
    /// Pixels of a still image (`width * height`).
    pub max_still_pixels: u64,
    /// Longest side of an animation's canvas.
    pub max_anim_side: u32,
    /// Frames of an animation.
    pub max_frames: u32,
    /// Canvas pixels times frames: what Skia composites to play the whole animation.
    pub max_anim_pixels: u64,
    /// Wall clock for the whole check.
    pub max_time: Duration,
    /// Largest single allocation a decoder may make.
    pub max_alloc: u64,
}

impl Budget {
    /// Covers a 48 MP phone photo and a long GIF; a hostile file costs at most this.
    pub(crate) const PEER: Budget = Budget {
        max_bytes: 128 * 1024 * 1024,
        max_side: 16_384,
        max_still_pixels: 50_331_648,
        max_anim_side: 4_096,
        max_frames: 10_000,
        max_anim_pixels: 268_435_456,
        max_time: Duration::from_secs(30),
        max_alloc: 256 * 1024 * 1024,
    };
}

/// The formats a peer image may be in, decided by magic bytes: Skia picks its codec
/// the same way, never by file name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Format {
    Png,
    Apng,
    Jpeg,
    Gif,
    WebP,
    AnimatedWebP,
}

/// What a passing image is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Facts {
    pub format: Format,
    pub width: u32,
    pub height: u32,
    pub frames: u32,
}

/// Why an image is refused. Every variant means Skia never sees the bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Refusal {
    Empty,
    TooManyBytes,
    UnknownFormat,
    OverCanvas { width: u32, height: u32 },
    TooManyFrames,
    OverPixelBudget,
    OverTime,
    NoFrames,
    Undecodable(String),
    /// The decode would allocate past `max_alloc` (a 16-bit canvas, a progressive JPEG's
    /// coefficient planes), refused from the header before any allocation.
    OverMemory,
    /// A JPEG carrying a multi-picture (MPF) index: Skia may parse the index and the
    /// secondary images after EOI, which our decoder never reads.
    MultiPicture,
    Panicked,
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Refusal::Empty => write!(f, "is empty"),
            Refusal::TooManyBytes => write!(f, "is over the byte ceiling"),
            Refusal::UnknownFormat => write!(f, "is not PNG, JPEG, GIF or WebP"),
            Refusal::OverCanvas { width, height } => write!(f, "declares a {width}x{height} canvas"),
            Refusal::TooManyFrames => write!(f, "has too many frames"),
            Refusal::OverPixelBudget => write!(f, "is over the pixel budget"),
            Refusal::OverTime => write!(f, "took too long to decode"),
            Refusal::NoFrames => write!(f, "has no frames"),
            Refusal::Undecodable(e) => write!(f, "does not decode: {e}"),
            Refusal::Panicked => write!(f, "made the decoder panic"),
            Refusal::OverMemory => write!(f, "would decode past the memory budget"),
            Refusal::MultiPicture => write!(f, "carries a multi-picture JPEG index"),
        }
    }
}

/// The four containers a peer image may come in, by magic bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Magic {
    Png,
    Jpeg,
    Gif,
    WebP,
}

/// The container named by the leading bytes, or `None`.
pub(crate) fn sniff(bytes: &[u8]) -> Option<Magic> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some(Magic::Png)
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some(Magic::Jpeg)
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some(Magic::Gif)
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some(Magic::WebP)
    } else {
        None
    }
}

/// [`check_with`] under [`Budget::PEER`].
pub(crate) fn check(bytes: &[u8]) -> Result<Facts, Refusal> {
    check_with(bytes, &Budget::PEER)
}

/// Decodes every pixel of every frame, or says why not. Never panics: a decoder
/// panic is a refusal like any other.
pub(crate) fn check_with(bytes: &[u8], budget: &Budget) -> Result<Facts, Refusal> {
    let deadline = Instant::now() + budget.max_time;
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| decode_all(bytes, budget, deadline)))
        .unwrap_or(Err(Refusal::Panicked))
}

/// The check itself, panics and all; [`check_with`] is the only caller outside the fuzz
/// harness, which wants to see a panic.
pub(crate) fn decode_all(bytes: &[u8], budget: &Budget, deadline: Instant) -> Result<Facts, Refusal> {
    if bytes.is_empty() {
        return Err(Refusal::Empty);
    }
    if bytes.len() > budget.max_bytes {
        return Err(Refusal::TooManyBytes);
    }
    match sniff(bytes).ok_or(Refusal::UnknownFormat)? {
        Magic::Png => png(bytes, budget, deadline),
        Magic::Jpeg => {
            let header = jpeg_header(bytes);
            if header.multi_picture {
                return Err(Refusal::MultiPicture);
            }
            let decoder = image::codecs::jpeg::JpegDecoder::new(Cursor::new(bytes)).map_err(undecodable)?;
            // A progressive scan keeps every component's DCT coefficients (i16) until
            // the end, on top of the output buffer.
            let (w, h) = decoder.dimensions();
            let coefficients = if header.progressive {
                u64::from(w.div_ceil(16) * 16) * u64::from(h.div_ceil(16) * 16) * u64::from(header.components.max(1)) * 2
            } else {
                0
            };
            still(decoder, Format::Jpeg, budget, coefficients)
        }
        Magic::Gif => {
            let decoder = image::codecs::gif::GifDecoder::new(Cursor::new(bytes)).map_err(undecodable)?;
            animation(decoder, Format::Gif, budget, deadline)
        }
        Magic::WebP => webp(bytes, budget, deadline),
    }
}

fn undecodable(e: image::ImageError) -> Refusal {
    Refusal::Undecodable(e.to_string())
}

fn limits(budget: &Budget) -> image::Limits {
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(budget.max_alloc);
    limits
}

fn within_still(width: u32, height: u32, budget: &Budget) -> Result<(), Refusal> {
    if width == 0 || height == 0 || width > budget.max_side || height > budget.max_side {
        return Err(Refusal::OverCanvas { width, height });
    }
    if u64::from(width) * u64::from(height) > budget.max_still_pixels {
        return Err(Refusal::OverPixelBudget);
    }
    Ok(())
}

fn within_canvas(width: u32, height: u32, budget: &Budget) -> Result<(), Refusal> {
    if width == 0 || height == 0 || width > budget.max_anim_side || height > budget.max_anim_side {
        return Err(Refusal::OverCanvas { width, height });
    }
    Ok(())
}

/// One still image, decoded whole into a buffer its header sized.
/// `working` is what the decoder holds beside the output buffer; both count against
/// `max_alloc` BEFORE anything is allocated (`set_limits` alone does not reserve the
/// output, only `ImageReader::decode` does).
fn still<D: ImageDecoder>(mut decoder: D, format: Format, budget: &Budget, working: u64) -> Result<Facts, Refusal> {
    let (width, height) = decoder.dimensions();
    within_still(width, height, budget)?;
    if decoder.total_bytes().saturating_add(working) > budget.max_alloc {
        return Err(Refusal::OverMemory);
    }
    decoder.set_limits(limits(budget)).map_err(undecodable)?;
    let len = usize::try_from(decoder.total_bytes()).map_err(|_| Refusal::OverPixelBudget)?;
    let mut buf = vec![0u8; len];
    decoder.read_image(&mut buf).map_err(undecodable)?;
    Ok(Facts { format, width, height, frames: 1 })
}

/// Every frame of an animation, composited on its canvas as a player would.
fn animation<'a, D>(mut decoder: D, format: Format, budget: &Budget, deadline: Instant) -> Result<Facts, Refusal>
where
    D: ImageDecoder + AnimationDecoder<'a>,
{
    let (width, height) = decoder.dimensions();
    within_canvas(width, height, budget)?;
    // A frame out, the decoder's composited canvas and the previous one kept for
    // disposal: three RGBA canvases at once.
    if u64::from(width) * u64::from(height) * 4 * 3 > budget.max_alloc {
        return Err(Refusal::OverMemory);
    }
    decoder.set_limits(limits(budget)).map_err(undecodable)?;
    let frames = decode_frames(decoder.into_frames(), width, height, budget, deadline)?;
    Ok(Facts { format, width, height, frames })
}

fn decode_frames(
    frames: image::Frames<'_>,
    width: u32,
    height: u32,
    budget: &Budget,
    deadline: Instant,
) -> Result<u32, Refusal> {
    let canvas = u64::from(width) * u64::from(height);
    let mut count: u32 = 0;
    for frame in frames {
        frame.map_err(undecodable)?;
        count += 1;
        if count > budget.max_frames {
            return Err(Refusal::TooManyFrames);
        }
        if u64::from(count) * canvas > budget.max_anim_pixels {
            return Err(Refusal::OverPixelBudget);
        }
        if Instant::now() > deadline {
            return Err(Refusal::OverTime);
        }
    }
    if count == 0 {
        return Err(Refusal::NoFrames);
    }
    Ok(count)
}

/// A PNG, and for an APNG the default image AND every animation frame: Skia shows the
/// default image, a player shows the frames, and the default image need not be one.
fn png(bytes: &[u8], budget: &Budget, deadline: Instant) -> Result<Facts, Refusal> {
    let decoder = image::codecs::png::PngDecoder::new(Cursor::new(bytes)).map_err(undecodable)?;
    if !decoder.is_apng().map_err(undecodable)? {
        return still(decoder, Format::Png, budget, 0);
    }
    let (width, height) = decoder.dimensions();
    within_canvas(width, height, budget)?;
    still(decoder, Format::Png, budget, 0)?;
    let mut decoder = image::codecs::png::PngDecoder::new(Cursor::new(bytes)).map_err(undecodable)?;
    decoder.set_limits(limits(budget)).map_err(undecodable)?;
    let frames = decode_frames(decoder.apng().map_err(undecodable)?.into_frames(), width, height, budget, deadline)?;
    Ok(Facts { format: Format::Apng, width, height, frames })
}

/// What image-webp holds beside the output buffer (measured): VP8L an ARGB plane,
/// 4 bytes a pixel; VP8 its YUV and alpha planes, under 2. The sender sizes against
/// this too, so whatever Hollow sends passes.
pub(crate) fn webp_working_bytes(w: u32, h: u32, lossless: bool) -> u64 {
    u64::from(w) * u64::from(h) * if lossless { 4 } else { 2 }
}

/// True when the first image chunk of a still WebP is `VP8L`.
fn webp_is_lossless(bytes: &[u8]) -> bool {
    let mut i = 12;
    while i + 8 <= bytes.len() {
        let fourcc = &bytes[i..i + 4];
        if fourcc == b"VP8L" {
            return true;
        }
        if fourcc == b"VP8 " {
            return false;
        }
        let len = u32::from_le_bytes([bytes[i + 4], bytes[i + 5], bytes[i + 6], bytes[i + 7]]) as usize;
        i = match i.checked_add(8 + len + (len & 1)) {
            Some(n) => n,
            None => return true,
        };
    }
    true
}

/// What a JPEG's marker segments say before its first scan.
#[derive(Default)]
struct JpegHeader {
    progressive: bool,
    components: u8,
    multi_picture: bool,
}

/// Walks the marker segments up to the first SOS: SOF2 (progressive), the SOF's
/// component count, and an APP2 multi-picture or ISO 21496 gain-map segment.
fn jpeg_header(bytes: &[u8]) -> JpegHeader {
    let mut out = JpegHeader::default();
    let mut i = 2;
    while i + 4 <= bytes.len() {
        if bytes[i] != 0xFF {
            break;
        }
        let marker = bytes[i + 1];
        if marker == 0xFF {
            i += 1;
            continue;
        }
        if marker == 0xDA || marker == 0xD9 {
            break;
        }
        let len = usize::from(u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]));
        let body = bytes.get(i + 4..(i + 2 + len).min(bytes.len())).unwrap_or(&[]);
        match marker {
            0xC0..=0xCF if marker != 0xC4 && marker != 0xC8 && marker != 0xCC => {
                out.progressive |= matches!(marker, 0xC2 | 0xC6 | 0xCA | 0xCE);
                out.components = body.get(5).copied().unwrap_or(0);
            }
            // Flutter's Skia carries the ISO 21496 gain-map parser (its URN is in the
            // engine binary), and a gain map lives after EOI where we never decode.
            0xE2 if body.starts_with(b"MPF\0") || body.starts_with(b"urn:iso:std:iso:ts:21496") => {
                out.multi_picture = true
            }
            _ => {}
        }
        if len < 2 {
            break;
        }
        i += 2 + len;
    }
    out
}

fn webp(bytes: &[u8], budget: &Budget, deadline: Instant) -> Result<Facts, Refusal> {
    let decoder = image::codecs::webp::WebPDecoder::new(Cursor::new(bytes)).map_err(undecodable)?;
    if decoder.has_animation() {
        animation(decoder, Format::AnimatedWebP, budget, deadline)
    } else {
        let (w, h) = decoder.dimensions();
        still(decoder, Format::WebP, budget, webp_working_bytes(w, h, webp_is_lossless(bytes)))
    }
}

#[cfg(all(test, not(image_check_standalone)))]
mod tests {
    use super::*;
    use image::{Delay, Frame, ImageEncoder, Rgba, RgbaImage};

    fn pattern(w: u32, h: u32, seed: u8) -> RgbaImage {
        RgbaImage::from_fn(w, h, |x, y| {
            Rgba([(x as u8).wrapping_mul(7) ^ seed, (y as u8).wrapping_mul(13), seed, 255])
        })
    }

    fn png_bytes(w: u32, h: u32) -> Vec<u8> {
        let mut out = Vec::new();
        image::codecs::png::PngEncoder::new(&mut out)
            .write_image(pattern(w, h, 3).as_raw(), w, h, image::ExtendedColorType::Rgba8)
            .unwrap();
        out
    }

    fn jpeg_bytes(w: u32, h: u32) -> Vec<u8> {
        let rgb = image::DynamicImage::ImageRgba8(pattern(w, h, 9)).to_rgb8();
        let mut out = Vec::new();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 80)
            .write_image(rgb.as_raw(), w, h, image::ExtendedColorType::Rgb8)
            .unwrap();
        out
    }

    fn gif_bytes(w: u32, h: u32, frames: u8) -> Vec<u8> {
        let mut out = Vec::new();
        {
            let mut enc = image::codecs::gif::GifEncoder::new(&mut out);
            for i in 0..frames {
                enc.encode_frame(Frame::from_parts(pattern(w, h, i * 40), 0, 0, Delay::from_numer_denom_ms(100, 1)))
                    .unwrap();
            }
        }
        out
    }

    fn webp_lossless_bytes(w: u32, h: u32) -> Vec<u8> {
        let mut out = Vec::new();
        image::codecs::webp::WebPEncoder::new_lossless(&mut out)
            .write_image(pattern(w, h, 5).as_raw(), w, h, image::ExtendedColorType::Rgba8)
            .unwrap();
        out
    }

    fn webp_lossy_bytes(w: u32, h: u32) -> Vec<u8> {
        let params = crate::node::webp_anim::AnimParams::plain(75.0);
        crate::node::webp_anim::encode_still(pattern(w, h, 11).as_raw(), w, h, &params).unwrap()
    }

    fn webp_animated_bytes(w: u32, h: u32, frames: u8) -> Vec<u8> {
        let frames: Vec<(RgbaImage, i32)> = (0..frames).map(|i| (pattern(w, h, i * 30), 100)).collect();
        let params = crate::node::webp_anim::AnimParams::art(75.0);
        crate::node::webp_anim::encode_animation(&frames, (w, h), &params).unwrap()
    }

    /// A minimal APNG: an IHDR, acTL and two fcTL/IDAT-or-fdAT frames, CRCs real.
    fn apng_bytes(w: u32, h: u32) -> Vec<u8> {
        apng_with(w, h, false, false)
    }

    /// `hidden_default`: the IDAT image is no frame (Skia's still, a player's nothing);
    /// `bad_default`: its pixel stream is not valid zlib.
    fn apng_with(w: u32, h: u32, hidden_default: bool, bad_default: bool) -> Vec<u8> {
        fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
            out.extend_from_slice(&(data.len() as u32).to_be_bytes());
            let start = out.len();
            out.extend_from_slice(kind);
            out.extend_from_slice(data);
            let crc = crc32(&out[start..]);
            out.extend_from_slice(&crc.to_be_bytes());
        }
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
        fn zlib_rows(w: u32, h: u32, seed: u8) -> Vec<u8> {
            let mut raw = Vec::new();
            for y in 0..h {
                raw.push(0);
                for x in 0..w {
                    raw.extend_from_slice(&[(x as u8) ^ seed, y as u8, seed, 255]);
                }
            }
            let mut z = vec![0x78, 0x01];
            for (i, block) in raw.chunks(65_535).enumerate() {
                let last = (i + 1) * 65_535 >= raw.len();
                z.push(u8::from(last));
                z.extend_from_slice(&(block.len() as u16).to_le_bytes());
                z.extend_from_slice(&(!(block.len() as u16)).to_le_bytes());
                z.extend_from_slice(block);
            }
            let (mut a, mut b) = (1u32, 0u32);
            for &x in &raw {
                a = (a + u32::from(x)) % 65_521;
                b = (b + a) % 65_521;
            }
            z.extend_from_slice(&((b << 16) | a).to_be_bytes());
            z
        }
        fn fctl(seq: u32, w: u32, h: u32) -> Vec<u8> {
            let mut d = Vec::new();
            d.extend_from_slice(&seq.to_be_bytes());
            d.extend_from_slice(&w.to_be_bytes());
            d.extend_from_slice(&h.to_be_bytes());
            d.extend_from_slice(&0u32.to_be_bytes());
            d.extend_from_slice(&0u32.to_be_bytes());
            d.extend_from_slice(&1u16.to_be_bytes());
            d.extend_from_slice(&10u16.to_be_bytes());
            d.extend_from_slice(&[0, 0]);
            d
        }
        let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
        let mut ihdr = Vec::new();
        ihdr.extend_from_slice(&w.to_be_bytes());
        ihdr.extend_from_slice(&h.to_be_bytes());
        ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
        chunk(&mut out, b"IHDR", &ihdr);
        let mut actl = Vec::new();
        actl.extend_from_slice(&(if hidden_default { 1u32 } else { 2u32 }).to_be_bytes());
        actl.extend_from_slice(&0u32.to_be_bytes());
        chunk(&mut out, b"acTL", &actl);
        let mut seq = 0u32;
        if !hidden_default {
            chunk(&mut out, b"fcTL", &fctl(seq, w, h));
            seq += 1;
        }
        let mut idat = zlib_rows(w, h, 1);
        if bad_default {
            let n = idat.len();
            for b in &mut idat[7..n - 4] {
                *b = 0xFF;
            }
        }
        chunk(&mut out, b"IDAT", &idat);
        chunk(&mut out, b"fcTL", &fctl(seq, w, h));
        let mut fdat = (seq + 1).to_be_bytes().to_vec();
        fdat.extend_from_slice(&zlib_rows(w, h, 90));
        chunk(&mut out, b"fdAT", &fdat);
        chunk(&mut out, b"IEND", &[]);
        out
    }

    /// Every kind a peer can send, valid, with its expected facts.
    pub(crate) fn valid_corpus() -> Vec<(&'static str, Vec<u8>, Format, u32)> {
        vec![
            ("png", png_bytes(40, 30), Format::Png, 1),
            ("apng", apng_bytes(24, 16), Format::Apng, 2),
            ("jpeg", jpeg_bytes(48, 32), Format::Jpeg, 1),
            ("gif", gif_bytes(20, 20, 3), Format::Gif, 3),
            ("webp lossless", webp_lossless_bytes(33, 17), Format::WebP, 1),
            ("webp lossy", webp_lossy_bytes(64, 48), Format::WebP, 1),
            ("webp animated", webp_animated_bytes(32, 32, 4), Format::AnimatedWebP, 4),
        ]
    }

    #[test]
    fn every_valid_kind_passes_with_its_true_shape() {
        for (what, bytes, format, frames) in valid_corpus() {
            let before = bytes.clone();
            let facts = check(&bytes).unwrap_or_else(|e| panic!("valid {what} refused: {e}"));
            assert_eq!(facts.format, format, "{what}");
            assert_eq!(facts.frames, frames, "{what}");
            assert_eq!(bytes, before, "the check must never touch the bytes ({what})");
        }
    }

    #[test]
    fn wrong_magic_is_refused_before_any_decoder() {
        assert_eq!(check(&[]), Err(Refusal::Empty));
        let mut bmp = b"BM".to_vec();
        bmp.resize(200, 0);
        assert_eq!(check(&bmp), Err(Refusal::UnknownFormat));
        // A PNG body behind another magic is still not a PNG.
        let mut png = png_bytes(8, 8);
        png[0] = b'x';
        assert_eq!(check(&png), Err(Refusal::UnknownFormat));
        assert_eq!(check(b"<svg xmlns='http://www.w3.org/2000/svg'/>"), Err(Refusal::UnknownFormat));
    }

    /// A JPEG cut inside its entropy-coded scan is the exception: libjpeg-turbo paints
    /// what is there, and so did our decoder, so it is no reason to refuse.
    #[test]
    fn a_truncated_image_of_every_kind_is_refused() {
        for (what, bytes, ..) in valid_corpus() {
            let cuts: &[usize] = if what == "jpeg" {
                &[40]
            } else {
                &[bytes.len() * 3 / 4, bytes.len() / 2, 40]
            };
            for &cut in cuts {
                assert!(check(&bytes[..cut]).is_err(), "{what} cut to {cut} of {} passed", bytes.len());
            }
        }
    }

    /// The header says huge, the file is tiny: refused from the header, no allocation.
    #[test]
    fn an_oversized_canvas_is_refused_from_its_header() {
        let mut png = png_bytes(8, 8);
        png[16..20].copy_from_slice(&20_000u32.to_be_bytes());
        assert!(matches!(check(&png), Err(Refusal::OverCanvas { width: 20_000, .. }) | Err(Refusal::Undecodable(_))));

        let mut gif = gif_bytes(8, 8, 1);
        gif[6..8].copy_from_slice(&5_000u16.to_le_bytes());
        gif[8..10].copy_from_slice(&5_000u16.to_le_bytes());
        assert_eq!(check(&gif), Err(Refusal::OverCanvas { width: 5_000, height: 5_000 }));

        let tight = Budget { max_side: 32, ..Budget::PEER };
        assert_eq!(check_with(&png_bytes(40, 30), &tight), Err(Refusal::OverCanvas { width: 40, height: 30 }));
        let few = Budget { max_still_pixels: 1_000, ..Budget::PEER };
        assert_eq!(check_with(&jpeg_bytes(48, 32), &few), Err(Refusal::OverPixelBudget));
    }

    /// Many frames on a big canvas: what Skia composites, not what the file weighs.
    #[test]
    fn a_frame_bomb_is_refused_by_canvas_times_frames() {
        let gif = gif_bytes(40, 40, 6);
        assert!(check(&gif).is_ok());
        let budget = Budget { max_anim_pixels: 40 * 40 * 5, ..Budget::PEER };
        assert_eq!(check_with(&gif, &budget), Err(Refusal::OverPixelBudget));
        let budget = Budget { max_frames: 5, ..Budget::PEER };
        assert_eq!(check_with(&gif, &budget), Err(Refusal::TooManyFrames));
        let webp = webp_animated_bytes(32, 32, 4);
        let budget = Budget { max_anim_pixels: 32 * 32 * 3, ..Budget::PEER };
        assert_eq!(check_with(&webp, &budget), Err(Refusal::OverPixelBudget));
        let apng = apng_bytes(24, 16);
        let budget = Budget { max_frames: 1, ..Budget::PEER };
        assert_eq!(check_with(&apng, &budget), Err(Refusal::TooManyFrames));
    }

    /// Skia paints an APNG's default image, which need not be a frame: a corrupt one
    /// behind valid frames must not pass.
    #[test]
    fn an_apng_whose_hidden_default_image_is_corrupt_is_refused() {
        let ok = apng_with(24, 16, true, false);
        assert_eq!(check(&ok).map(|f| (f.format, f.frames)), Ok((Format::Apng, 1)));
        assert!(check(&apng_with(24, 16, true, true)).is_err());
    }

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

    /// A 16-bit RGBA canvas of 7000x7000 is 373 MiB of output from a tiny file: refused
    /// from the header, before the buffer exists (review MED-1, `imgs/big16.png`).
    #[test]
    fn a_decode_past_the_memory_budget_is_refused_before_allocating() {
        let img = image::ImageBuffer::<image::Rgba<u16>, Vec<u16>>::from_pixel(8, 8, image::Rgba([1, 2, 3, 65535]));
        let mut png = Vec::new();
        image::DynamicImage::ImageRgba16(img)
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        assert!(check(&png).is_ok(), "CONTROL: a small 16-bit PNG passes");
        png[16..20].copy_from_slice(&7000u32.to_be_bytes());
        png[20..24].copy_from_slice(&7000u32.to_be_bytes());
        let crc = crc32(&png[12..29]);
        png[29..33].copy_from_slice(&crc.to_be_bytes());
        assert_eq!(check(&png), Err(Refusal::OverMemory));

        // A progressive JPEG holds every coefficient plane beside its output.
        let mut jpeg = jpeg_bytes(48, 32);
        let sof = jpeg.windows(2).position(|w| w == [0xFF, 0xC0]).expect("a baseline SOF");
        jpeg[sof + 1] = 0xC2;
        jpeg[sof + 5..sof + 7].copy_from_slice(&6000u16.to_be_bytes());
        jpeg[sof + 7..sof + 9].copy_from_slice(&8000u16.to_be_bytes());
        assert_eq!(check(&jpeg), Err(Refusal::OverMemory));

        let gif = gif_bytes(20, 20, 2);
        let tight = Budget { max_alloc: 20 * 20 * 4 * 3 - 1, ..Budget::PEER };
        assert_eq!(check_with(&gif, &tight), Err(Refusal::OverMemory));
        let webp = webp_lossless_bytes(33, 17);
        let tight = Budget { max_alloc: 33 * 17 * 4, ..Budget::PEER };
        assert_eq!(check_with(&webp, &tight), Err(Refusal::OverMemory));
    }

    /// A multi-picture JPEG (UltraHDR gain map, MPF): its index and the images after EOI
    /// are bytes our decoder never reads.
    #[test]
    fn a_multi_picture_jpeg_is_refused() {
        let plain = jpeg_bytes(48, 32);
        let mut mpf = plain[..2].to_vec();
        let body = b"MPF\0II*\0\x08\0\0\0";
        mpf.extend_from_slice(&[0xFF, 0xE2]);
        mpf.extend_from_slice(&((body.len() + 2) as u16).to_be_bytes());
        mpf.extend_from_slice(body);
        mpf.extend_from_slice(&plain[2..]);
        assert!(check(&plain).is_ok());
        assert_eq!(check(&mpf), Err(Refusal::MultiPicture));

        let mut iso = plain[..2].to_vec();
        let body = b"urn:iso:std:iso:ts:21496:-1\0\0\0";
        iso.extend_from_slice(&[0xFF, 0xE2]);
        iso.extend_from_slice(&((body.len() + 2) as u16).to_be_bytes());
        iso.extend_from_slice(body);
        iso.extend_from_slice(&plain[2..]);
        assert_eq!(check(&iso), Err(Refusal::MultiPicture), "an ISO 21496 gain map");
    }

    #[test]
    fn an_animation_over_its_canvas_side_is_refused() {
        let budget = Budget { max_anim_side: 16, ..Budget::PEER };
        assert_eq!(check_with(&gif_bytes(20, 20, 2), &budget), Err(Refusal::OverCanvas { width: 20, height: 20 }));
        assert_eq!(
            check_with(&webp_animated_bytes(32, 32, 2), &budget),
            Err(Refusal::OverCanvas { width: 32, height: 32 })
        );
        // A still of the same size is held to the still rule instead.
        assert!(check_with(&png_bytes(20, 20), &budget).is_ok());
    }

    #[test]
    fn a_slow_animation_is_refused_on_time() {
        let budget = Budget { max_time: Duration::ZERO, ..Budget::PEER };
        assert_eq!(check_with(&gif_bytes(20, 20, 3), &budget), Err(Refusal::OverTime));
    }

    #[test]
    fn a_file_over_the_byte_ceiling_is_refused_unread() {
        let budget = Budget { max_bytes: 100, ..Budget::PEER };
        assert_eq!(check_with(&png_bytes(40, 30), &budget), Err(Refusal::TooManyBytes));
    }

    /// A corrupt pixel stream behind a valid header: only a FULL decode sees it.
    #[test]
    fn a_corrupt_body_behind_a_valid_header_is_refused() {
        let mut webp = webp_lossy_bytes(64, 48);
        let n = webp.len();
        for b in &mut webp[40..n - 8] {
            *b = 0xFF;
        }
        assert!(check(&webp).is_err(), "a lossy WebP with a garbage bitstream passed");

        let mut gif = gif_bytes(20, 20, 3);
        let n = gif.len();
        gif.truncate(n - 30);
        gif.push(0x3B);
        assert!(check(&gif).is_err(), "a GIF whose last frame is cut short passed");
    }

    /// Bytes after the image end do not reach Skia's decoders either (RIFF size, IEND,
    /// GIF trailer, EOI), so they are not a reason to refuse.
    #[test]
    fn trailing_bytes_after_a_complete_image_pass() {
        for (what, mut bytes, ..) in valid_corpus() {
            bytes.extend_from_slice(&[0xAB; 64]);
            assert!(check(&bytes).is_ok(), "{what} with trailing bytes refused");
        }
    }

    /// Inputs cargo-fuzz found that panic `image-webp` 0.2.4 (`yuv.rs`, a slice past
    /// its end): a panic is a refusal, never an unwind into the caller.
    pub(crate) const PANICKING_WEBPS: [&[u8]; 8] = [
        include_bytes!("image_check_fixtures/webp_panic_1.webp"),
        include_bytes!("image_check_fixtures/webp_panic_2.webp"),
        include_bytes!("image_check_fixtures/webp_panic_3.webp"),
        include_bytes!("image_check_fixtures/webp_panic_4.webp"),
        include_bytes!("image_check_fixtures/webp_panic_5.webp"),
        include_bytes!("image_check_fixtures/webp_panic_6.webp"),
        include_bytes!("image_check_fixtures/webp_panic_7.webp"),
        include_bytes!("image_check_fixtures/webp_panic_8.webp"),
    ];

    #[test]
    fn a_decoder_panic_is_a_refusal() {
        for (i, bytes) in PANICKING_WEBPS.iter().enumerate() {
            assert!(check(bytes).is_err(), "fuzz input {} passed", i + 1);
        }
        assert!(
            PANICKING_WEBPS.iter().any(|b| check(b) == Err(Refusal::Panicked)),
            "the fixtures no longer panic image-webp: drop them, or upstream fixed it"
        );
    }

    /// The fuzz harness's job, run in CI on a fixed seed: mutated copies of every kind
    /// never panic a decoder and never outlast the budget.
    #[test]
    fn mutated_corpus_never_panics_or_hangs() {
        let corpus = valid_corpus();
        let mut rng = 0x2545_F491_4F6C_DD1Du64;
        let mut next = move || {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            rng
        };
        let budget = Budget { max_time: Duration::from_secs(5), ..Budget::PEER };
        let started = Instant::now();
        let mut refused = 0usize;
        let rounds = 600;
        for (what, seed, ..) in &corpus {
            for _ in 0..rounds {
                let mut b = seed.clone();
                for _ in 0..=(next() % 4) {
                    let at = (next() as usize) % b.len().max(1);
                    match next() % 6 {
                        0 => b[at] ^= 1 << (next() % 8),
                        1 => b[at] = next() as u8,
                        2 => b.truncate(at.max(1)),
                        3 => {
                            let len = (next() as usize % 16).min(b.len() - at);
                            let run: Vec<u8> = b[at..at + len].to_vec();
                            b.splice(at..at, run);
                        }
                        4 => b.insert(at, next() as u8),
                        _ => {
                            let v = [0x00, 0xFF, 0x7F, 0x80][(next() % 4) as usize];
                            for x in b.iter_mut().skip(at).take(4) {
                                *x = v;
                            }
                        }
                    }
                }
                let one = Instant::now();
                let r = std::panic::catch_unwind(|| decode_all(&b, &budget, Instant::now() + budget.max_time));
                assert!(r.is_ok(), "a mutated {what} panicked a decoder: {}", hex::encode(&b));
                assert!(one.elapsed() < Duration::from_secs(5), "a mutated {what} took {:?}", one.elapsed());
                refused += usize::from(r.unwrap().is_err());
            }
        }
        assert!(refused > 0, "no mutation was ever refused, so the harness is not mutating");
        assert!(started.elapsed() < Duration::from_secs(120));
    }
}
