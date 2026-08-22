//! Image conversion utilities — WebP encoding for file sharing, avatars, and banners.

use image::codecs::gif::GifDecoder;
use image::imageops::FilterType;
use image::{AnimationDecoder, ImageFormat};
use std::io::Cursor;

use super::webp_anim;

/// User-configurable image quality tier for the outgoing image pipeline.
///
/// Applied to every user-uploaded image that goes through the file-send
/// path in `swarm.rs`. Does NOT affect link preview thumbnails (those
/// always use `convert_to_webp_preview` at Q=50 / 400px, because the
/// user didn't opt into those image uploads and can't meaningfully
/// override their fidelity).
///
/// Phase 6.75 image quality tiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WebpQuality {
    /// Lossless WebP via the `image` crate. ~20-40% smaller than PNG.
    /// For users who share pixel art, screenshots with tiny text, or
    /// diagrams where artifacts would matter.
    Lossless,
    /// Lossy WebP at Q=50. ~95-98% smaller than PNG on photographic
    /// content, visually indistinguishable at render sizes. Default for
    /// new installs.
    Balanced,
    /// Lossy WebP at Q=30. More aggressive than Balanced — noticeable
    /// on gradients but still fine for casual photos. Use for very
    /// low-bandwidth or quota-constrained situations.
    Small,
}

impl WebpQuality {
    /// Parse from the string stored in `app_settings`. Falls back to
    /// Balanced for any unknown or missing value.
    pub fn from_setting(s: &str) -> Self {
        match s {
            "lossless" => Self::Lossless,
            "small" => Self::Small,
            _ => Self::Balanced,
        }
    }

    /// Serialize for `app_settings` storage.
    pub fn as_setting(&self) -> &'static str {
        match self {
            Self::Lossless => "lossless",
            Self::Balanced => "balanced",
            Self::Small => "small",
        }
    }
}

impl Default for WebpQuality {
    fn default() -> Self {
        Self::Balanced
    }
}

/// Extensions that should be converted to WebP on send.
/// GIFs are excluded to preserve animation frames.
pub fn should_convert_to_webp(ext: &str) -> bool {
    matches!(
        ext.to_lowercase().as_str(),
        "png" | "jpg" | "jpeg" | "bmp" | "tiff" | "tif"
    )
}

/// Strip metadata from a WebP file by decoding to pixels and re-encoding.
/// Returns the cleaned WebP bytes with the same quality. Since the input is
/// already WebP, we use lossless re-encode to avoid generation loss.
pub fn strip_webp_metadata(data: &[u8]) -> Result<Vec<u8>, String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode WebP for metadata strip: {e}"))?;
    let mut buf = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut buf);
    img.write_to(&mut cursor, ImageFormat::WebP)
        .map_err(|e| format!("Failed to re-encode WebP: {e}"))?;
    Ok(buf)
}

/// Strip EXIF/metadata from a GIF without re-encoding (preserves animation).
/// GIF metadata lives in Application Extension blocks (APP1/XMP) and Comment
/// Extension blocks. We keep only the essential GIF structure: Header,
/// Logical Screen Descriptor, Global Color Table, and image/animation data.
///
/// Strategy: rebuild the GIF keeping only recognized essential blocks.
/// This is simpler and safer than trying to surgically remove specific chunks.
pub fn strip_gif_metadata(data: &[u8]) -> Vec<u8> {
    // GIF files can contain metadata in:
    // - Comment Extension (0x21, 0xFE)
    // - Application Extension (0x21, 0xFF) — EXIF, XMP, etc.
    //   Exception: NETSCAPE2.0 extension (animation loop control) must be kept.
    //
    // We scan the GIF and copy everything EXCEPT Comment and non-NETSCAPE
    // Application Extension blocks.

    if data.len() < 13 || &data[0..3] != b"GIF" {
        return data.to_vec(); // Not a GIF, return as-is.
    }

    let mut out = Vec::with_capacity(data.len());
    let mut i = 0;

    // Copy header (6 bytes) + Logical Screen Descriptor (7 bytes).
    let lsd_end = 13;
    if data.len() < lsd_end {
        return data.to_vec();
    }
    out.extend_from_slice(&data[..lsd_end]);
    i = lsd_end;

    // Copy Global Color Table if present.
    let packed = data[10];
    let has_gct = (packed & 0x80) != 0;
    if has_gct {
        let gct_size = 3 * (1 << ((packed & 0x07) + 1));
        let gct_end = i + gct_size as usize;
        if gct_end > data.len() {
            return data.to_vec();
        }
        out.extend_from_slice(&data[i..gct_end]);
        i = gct_end;
    }

    // Process blocks.
    while i < data.len() {
        match data[i] {
            0x3B => {
                // Trailer — end of GIF.
                out.push(0x3B);
                break;
            }
            0x2C => {
                // Image Descriptor — always keep.
                let Some(next) = copy_gif_image_descriptor(data, i, &mut out) else { break; };
                i = next;
            }
            0x21 => {
                // Extension block.
                let Some(next) = copy_gif_extension(data, i, &mut out) else { break; };
                i = next;
            }
            _ => {
                // Unknown block type — just copy byte and advance.
                out.push(data[i]);
                i += 1;
            }
        }
    }

    out
}

/// Copy a GIF Image Descriptor block (0x2C) into `out`.
/// Copy: Image Descriptor (10 bytes) + optional LCT + image data.
/// Returns the new cursor position, or `None` when the data is truncated
/// and block processing should stop.
fn copy_gif_image_descriptor(data: &[u8], mut i: usize, out: &mut Vec<u8>) -> Option<usize> {
    if i + 10 > data.len() { return None; }
    out.extend_from_slice(&data[i..i + 10]);
    let img_packed = data[i + 9];
    let has_lct = (img_packed & 0x80) != 0;
    i += 10;
    if has_lct {
        let lct_size = 3 * (1 << ((img_packed & 0x07) + 1));
        let lct_end = i + lct_size as usize;
        if lct_end > data.len() { return None; }
        out.extend_from_slice(&data[i..lct_end]);
        i = lct_end;
    }
    // LZW Minimum Code Size byte.
    if i >= data.len() { return None; }
    out.push(data[i]);
    i += 1;
    // Sub-blocks until block terminator (0x00).
    while i < data.len() {
        let block_size = data[i] as usize;
        out.push(data[i]);
        i += 1;
        if block_size == 0 { break; }
        if i + block_size > data.len() { break; }
        out.extend_from_slice(&data[i..i + block_size]);
        i += block_size;
    }
    Some(i)
}

/// Copy or strip a GIF extension block (0x21) depending on its label.
/// Returns the new cursor position, or `None` when the data is truncated
/// and block processing should stop.
fn copy_gif_extension(data: &[u8], i: usize, out: &mut Vec<u8>) -> Option<usize> {
    if i + 2 > data.len() { return None; }
    let label = data[i + 1];
    match label {
        0xF9 => {
            // Graphic Control Extension — always keep (animation timing).
            // Fixed size: 2 (introducer+label) + 1 (block size=4) + 4 + 1 (terminator) = 8
            let block_end = i + 8;
            if block_end > data.len() { return None; }
            out.extend_from_slice(&data[i..block_end]);
            Some(block_end)
        }
        0xFF => copy_gif_application_extension(data, i, out),
        0xFE => {
            // Comment Extension — skip entirely.
            Some(skip_gif_sub_blocks(data, i + 2))
        }
        _ => {
            // Unknown extension — keep it (could be essential).
            let ext_start = i;
            // Skip sub-blocks.
            let end = skip_gif_sub_blocks(data, i + 2);
            out.extend_from_slice(&data[ext_start..end]);
            Some(end)
        }
    }
}

/// Application Extension (0xFF) — keep only NETSCAPE2.0 (animation loop).
/// Read past: introducer(1) + label(1) + block_size(1) + app_id(block_size) + sub-blocks
fn copy_gif_application_extension(data: &[u8], i: usize, out: &mut Vec<u8>) -> Option<usize> {
    if i + 3 > data.len() { return None; }
    let app_block_size = data[i + 2] as usize;
    let app_id_end = i + 3 + app_block_size;
    if app_id_end > data.len() { return None; }

    let is_netscape = app_block_size >= 11
        && &data[i + 3..i + 3 + 8] == b"NETSCAPE";

    // Collect the full extension (header + all sub-blocks).
    let ext_start = i;
    let end = skip_gif_sub_blocks(data, app_id_end);

    if is_netscape {
        out.extend_from_slice(&data[ext_start..end]);
    }
    // Otherwise: skip (strips EXIF, XMP, ICC, etc.)
    Some(end)
}

/// Advance past GIF data sub-blocks until the 0x00 terminator (or end of data).
/// Returns the position just past the terminator.
fn skip_gif_sub_blocks(data: &[u8], mut i: usize) -> usize {
    while i < data.len() {
        let sb = data[i] as usize;
        i += 1;
        if sb == 0 { break; }
        i += sb;
    }
    i
}

/// Convert an animated GIF to animated WebP at the given quality tier.
///
/// Decodes each GIF frame (the `image` crate handles disposal methods and
/// compositing), then encodes into animated WebP via `webp_animation::Encoder`.
/// Frame delays are preserved with the browser convention: delays < 20ms are
/// treated as 100ms (matching `animated_gif_image.dart`).
///
/// All quality tiers convert — even lossless WebP beats GIF's LZW compression.
///
/// Returns `(webp_bytes, width, height)`.
pub fn convert_gif_to_animated_webp(
    data: &[u8],
    quality: WebpQuality,
) -> Result<(Vec<u8>, u32, u32), String> {
    let decoder = GifDecoder::new(Cursor::new(data))
        .map_err(|e| format!("Failed to decode GIF: {e}"))?;
    let frames = decoder
        .into_frames()
        .collect_frames()
        .map_err(|e| format!("Failed to collect GIF frames: {e}"))?;

    if frames.is_empty() {
        return Err("GIF has no frames".into());
    }

    let (w, h) = (frames[0].buffer().width(), frames[0].buffer().height());
    if w == 0 || h == 0 {
        return Err("GIF has zero dimensions".into());
    }

    // The file-send pipeline carries arbitrary content, so it keeps libwebp's
    // general tuning rather than the art preset.
    let params = match quality {
        // Lossless effort 60: past that the returns are tiny and the wait is not.
        WebpQuality::Lossless => webp_anim::AnimParams::lossless(60.0),
        WebpQuality::Balanced => webp_anim::AnimParams::plain(50.0),
        WebpQuality::Small => webp_anim::AnimParams::plain(30.0),
    };

    // Browser convention: delays < 20ms → 100ms.
    let timed: Vec<(image::RgbaImage, i32)> = frames
        .into_iter()
        .map(|f| {
            let delay: std::time::Duration = f.delay().into();
            let ms = delay.as_millis() as i32;
            (f.into_buffer(), if ms < 20 { 100 } else { ms })
        })
        .collect();

    let webp_data = webp_anim::encode_animation(&timed, (w, h), &params)?;
    Ok((webp_data, w, h))
}

/// Convert image bytes to lossless WebP.
/// Returns (webp_bytes, width, height).
pub fn convert_to_webp_lossless(data: &[u8]) -> Result<(Vec<u8>, u32, u32), String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode image: {e}"))?;

    let width = img.width();
    let height = img.height();

    let mut buf = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut buf);

    img.write_to(&mut cursor, ImageFormat::WebP)
        .map_err(|e| format!("Failed to encode WebP: {e}"))?;

    Ok((buf, width, height))
}

/// Convert image bytes to WebP at the quality tier chosen by the user.
/// Preserves dimensions (no resize). This is the main entry point for
/// the user-configurable image send pipeline — callers should always
/// use this rather than calling the lossless/preview functions directly.
///
/// For `Lossless`, delegates to `convert_to_webp_lossless`.
/// For `Balanced` / `Small`, uses the `webp` crate at Q=50 / Q=30.
///
/// Returns `(webp_bytes, width, height)`. Phase 6.75.
pub fn convert_to_webp_with_quality(
    data: &[u8],
    quality: WebpQuality,
) -> Result<(Vec<u8>, u32, u32), String> {
    if quality == WebpQuality::Lossless {
        return convert_to_webp_lossless(data);
    }

    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode image: {e}"))?;
    let (w, h) = (img.width(), img.height());
    if w == 0 || h == 0 {
        return Err("Image has zero dimensions".into());
    }

    let q_value: f32 = match quality {
        WebpQuality::Balanced => 50.0,
        WebpQuality::Small => 30.0,
        WebpQuality::Lossless => unreachable!(), // handled above
    };

    let rgba = img.to_rgba8();
    let (ew, eh) = (rgba.width(), rgba.height());
    let bytes = encode_lossy_webp_via_animation(rgba.as_raw(), ew, eh, q_value)?;
    Ok((bytes, ew, eh))
}

/// Get image dimensions without converting.
pub fn get_image_dimensions(data: &[u8]) -> Result<(u32, u32), String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode image: {e}"))?;
    Ok((img.width(), img.height()))
}

/// Convert image bytes to lossy WebP at quality 50, resized so the max
/// dimension is `max_dim_px`. Preserves aspect ratio. Used for link preview
/// thumbnails and any other "small preview image" use case where file size
/// matters more than pixel-perfect fidelity.
///
/// Returns `(webp_bytes, width, height)` where the dimensions are the
/// resized dimensions actually encoded. Phase 6.75.
pub fn convert_to_webp_preview(data: &[u8], max_dim_px: u32) -> Result<(Vec<u8>, u32, u32), String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode image: {e}"))?;
    let (w, h) = (img.width(), img.height());
    if w == 0 || h == 0 {
        return Err("Image has zero dimensions".into());
    }

    // Resize so the larger dimension is at most max_dim_px. Preserve aspect.
    let resized = if w.max(h) > max_dim_px {
        let scale = max_dim_px as f32 / w.max(h) as f32;
        let nw = (w as f32 * scale).max(1.0) as u32;
        let nh = (h as f32 * scale).max(1.0) as u32;
        img.resize_exact(nw, nh, FilterType::Lanczos3)
    } else {
        img
    };

    let rgba = resized.to_rgba8();
    let (ew, eh) = (rgba.width(), rgba.height());
    let bytes = encode_lossy_webp_via_animation(rgba.as_raw(), ew, eh, 50.0)?;
    Ok((bytes, ew, eh))
}

/// Encode a single RGBA frame as lossy WebP at the given quality (0-100)
/// through the same libwebp animation encoder the animated paths use.
/// Sharing that path means only one libwebp-sys variant ends up in the final
/// binary (eliminates the macOS duplicate-symbol issue).
///
/// Uses the ART preset, because every caller here is user-uploaded artwork
/// (avatars, banners, emotes, showcase covers) rather than photography.
fn encode_lossy_webp_via_animation(rgba: &[u8], w: u32, h: u32, quality: f32) -> Result<Vec<u8>, String> {
    let img = image::RgbaImage::from_raw(w, h, rgba.to_vec())
        .ok_or_else(|| format!("Frame buffer is not {w}x{h} RGBA"))?;
    webp_anim::encode_animation(&[(img, 1)], (w, h), &webp_anim::AnimParams::art(quality))
}

/// Decode an animated source into `(frame, display-duration-ms)` pairs.
///
/// One place decides what "animated" means on the way IN, mirroring
/// [`is_animated_image`] on the way out: GIF, animated WebP, or an APNG.
/// Frame delays under 20ms become 100ms, the browser convention, so a GIF
/// authored with 0ms delays does not play at ticker speed.
pub fn decode_animation_frames(data: &[u8]) -> Result<Vec<(image::RgbaImage, i32)>, String> {
    let frames = if data.starts_with(b"GIF8") {
        GifDecoder::new(Cursor::new(data))
            .map_err(|e| format!("Failed to decode GIF: {e}"))?
            .into_frames()
            .collect_frames()
            .map_err(|e| format!("Failed to collect GIF frames: {e}"))?
    } else if is_animated_webp(data) {
        image::codecs::webp::WebPDecoder::new(Cursor::new(data))
            .map_err(|e| format!("Failed to decode animated WebP: {e}"))?
            .into_frames()
            .collect_frames()
            .map_err(|e| format!("Failed to collect WebP frames: {e}"))?
    } else if data.starts_with(b"\x89PNG") {
        let decoder = image::codecs::png::PngDecoder::new(Cursor::new(data))
            .map_err(|e| format!("Failed to decode PNG: {e}"))?;
        if !decoder.is_apng().map_err(|e| format!("Failed to read PNG: {e}"))? {
            return Err("PNG is not animated".into());
        }
        decoder
            .apng()
            .map_err(|e| format!("Failed to decode APNG: {e}"))?
            .into_frames()
            .collect_frames()
            .map_err(|e| format!("Failed to collect APNG frames: {e}"))?
    } else {
        return Err("Not an animated image".into());
    };

    if frames.is_empty() {
        return Err("Animation has no frames".into());
    }
    Ok(frames
        .into_iter()
        .map(|f| {
            let delay: std::time::Duration = f.delay().into();
            let ms = delay.as_millis() as i32;
            (f.into_buffer(), if ms < 20 { 100 } else { ms })
        })
        .collect())
}

/// Centre-crop every frame to `crop` then resize to `(dw, dh)`.
///
/// Skips the resize when the crop is already the target size. That is not
/// just a shortcut: resampling flat art manufactures intermediate colours
/// that were not in the source, and those cost real bytes. Measured on a
/// 224px animated source, a Lanczos3 downscale to 184 encoded 64% LARGER
/// than the untouched 224px original.
fn crop_resize_frames(
    frames: &[(image::RgbaImage, i32)],
    crop: (u32, u32, u32, u32),
    dw: u32,
    dh: u32,
) -> Vec<(image::RgbaImage, i32)> {
    let (x, y, cw, ch) = crop;
    frames
        .iter()
        .map(|(buf, ms)| {
            let cropped = image::imageops::crop_imm(buf, x, y, cw, ch).to_image();
            let out = if (cw, ch) == (dw, dh) {
                cropped
            } else {
                image::imageops::resize(&cropped, dw, dh, FilterType::Lanczos3)
            };
            (out, *ms)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a tiny solid-color PNG in memory for test input.
    fn make_test_png(w: u32, h: u32) -> Vec<u8> {
        let img = image::RgbaImage::from_pixel(w, h, image::Rgba([128, 64, 200, 255]));
        let mut buf = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut buf);
        img.write_to(&mut cursor, image::ImageFormat::Png)
            .expect("encode test png");
        buf
    }

    /// A cut-out source: fully transparent left half, opaque green right
    /// half — the shape of a real sticker.
    fn make_cutout_png(w: u32, h: u32) -> Vec<u8> {
        let mut img = image::RgbaImage::from_pixel(w, h, image::Rgba([0, 0, 0, 0]));
        for y in 0..h {
            for x in (w / 2)..w {
                img.put_pixel(x, y, image::Rgba([40, 200, 90, 255]));
            }
        }
        let mut buf = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Png)
            .expect("encode test png");
        buf
    }

    /// Alpha of one pixel, read through the decoder that actually
    /// understands our animation containers. `image::load_from_memory`
    /// reports 255 for every pixel of an ANMF WebP — see the note on
    /// [process_sticker_for_send].
    fn alpha_at(webp: &[u8], x: u32, y: u32, w: u32) -> u8 {
        let frame = webp_animation::Decoder::new(webp)
            .expect("decode webp")
            .into_iter()
            .next()
            .expect("at least one frame");
        frame.data()[((y * w + x) * 4 + 3) as usize]
    }

    // ── Avatar frames (issue #54) ─────────────────────────────────────

    /// A frame-shaped source: opaque ring around the outside, fully
    /// transparent middle. `hole` is the transparent square's side as a
    /// fraction of the canvas.
    fn make_frame_png(w: u32, h: u32, hole: f32) -> Vec<u8> {
        let mut img = image::RgbaImage::from_pixel(w, h, image::Rgba([200, 90, 40, 255]));
        let hw = (w as f32 * hole) as u32;
        let hh = (h as f32 * hole) as u32;
        let (x0, y0) = ((w - hw) / 2, (h - hh) / 2);
        for y in y0..(y0 + hh) {
            for x in x0..(x0 + hw) {
                img.put_pixel(x, y, image::Rgba([0, 0, 0, 0]));
            }
        }
        let mut buf = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Png)
            .expect("encode test png");
        buf
    }

    #[test]
    fn avatar_frame_accepts_a_see_through_middle() {
        // A 60% hole comfortably clears the 42% sampled disc.
        let png = make_frame_png(256, 256, 0.6);
        let (webp, animated) = process_avatar_frame(&png).expect("process frame");
        assert!(!animated, "a PNG source is a still frame");
        assert!(webp.len() <= 65_536, "still frame must fit the 64 KB cap");
        // 128x128, and the middle still reads through.
        assert_eq!(alpha_at(&webp, 64, 64, 128), 0, "the middle must stay transparent");
        assert_eq!(alpha_at(&webp, 2, 2, 128), 255, "the art must survive");
    }

    #[test]
    fn avatar_frame_refuses_a_blocked_middle() {
        // No hole at all — the classic "I uploaded my avatar as a frame".
        let png = make_test_png(256, 256);
        let err = process_avatar_frame(&png).expect_err("a solid image is not a frame");
        assert!(
            err.contains("transparent"),
            "the refusal must say what is wrong: {err}"
        );
        // A hole smaller than the sampled disc is still a blocked middle.
        let png = make_frame_png(256, 256, 0.15);
        assert!(process_avatar_frame(&png).is_err(), "a 15% hole blocks the avatar");
    }

    #[test]
    fn avatar_frame_centre_crops_to_square() {
        // Wide source: the centred square is what survives, so the hole
        // stays centred in the output rather than sliding off.
        let png = make_frame_png(400, 200, 0.7);
        let (webp, _) = process_avatar_frame(&png).expect("process frame");
        assert_eq!(alpha_at(&webp, 64, 64, 128), 0);
    }

    #[test]
    fn webp_preview_encodes_smaller_image() {
        let png = make_test_png(200, 100);
        let (webp_bytes, w, h) = convert_to_webp_preview(&png, 400).expect("encode");
        assert_eq!(w, 200);
        assert_eq!(h, 100);
        // Should decode cleanly via the image crate.
        let decoded = image::load_from_memory(&webp_bytes).expect("decode webp");
        assert_eq!(decoded.width(), 200);
        assert_eq!(decoded.height(), 100);
    }

    #[test]
    fn webp_preview_resizes_when_larger_than_max() {
        let png = make_test_png(1200, 600);
        let (webp_bytes, w, h) = convert_to_webp_preview(&png, 400).expect("encode");
        assert_eq!(w, 400);
        assert_eq!(h, 200); // preserved aspect ratio (1200:600 → 400:200)
        let decoded = image::load_from_memory(&webp_bytes).expect("decode webp");
        assert_eq!(decoded.width(), 400);
        assert_eq!(decoded.height(), 200);
    }

    #[test]
    fn webp_preview_rejects_invalid_bytes() {
        let result = convert_to_webp_preview(b"not an image", 400);
        assert!(result.is_err());
    }

    #[test]
    fn webp_quality_setting_roundtrip() {
        assert_eq!(WebpQuality::from_setting("lossless"), WebpQuality::Lossless);
        assert_eq!(WebpQuality::from_setting("balanced"), WebpQuality::Balanced);
        assert_eq!(WebpQuality::from_setting("small"), WebpQuality::Small);
        // Unknown / missing → Balanced (default).
        assert_eq!(WebpQuality::from_setting(""), WebpQuality::Balanced);
        assert_eq!(WebpQuality::from_setting("garbage"), WebpQuality::Balanced);
        // Serialization round-trip.
        for q in [WebpQuality::Lossless, WebpQuality::Balanced, WebpQuality::Small] {
            assert_eq!(WebpQuality::from_setting(q.as_setting()), q);
        }
    }

    #[test]
    fn webp_quality_default_is_balanced() {
        assert_eq!(WebpQuality::default(), WebpQuality::Balanced);
    }

    #[test]
    fn convert_with_quality_lossless_preserves_dimensions() {
        let png = make_test_png(200, 100);
        let (webp_bytes, w, h) =
            convert_to_webp_with_quality(&png, WebpQuality::Lossless).expect("encode");
        assert_eq!(w, 200);
        assert_eq!(h, 100);
        let decoded = image::load_from_memory(&webp_bytes).expect("decode webp");
        assert_eq!(decoded.width(), 200);
        assert_eq!(decoded.height(), 100);
    }

    #[test]
    fn convert_with_quality_balanced_preserves_dimensions() {
        let png = make_test_png(200, 100);
        let (webp_bytes, w, h) =
            convert_to_webp_with_quality(&png, WebpQuality::Balanced).expect("encode");
        assert_eq!(w, 200);
        assert_eq!(h, 100);
        let decoded = image::load_from_memory(&webp_bytes).expect("decode webp");
        assert_eq!(decoded.width(), 200);
        assert_eq!(decoded.height(), 100);
    }

    #[test]
    fn convert_with_quality_small_preserves_dimensions() {
        let png = make_test_png(400, 300);
        let (webp_bytes, w, h) =
            convert_to_webp_with_quality(&png, WebpQuality::Small).expect("encode");
        assert_eq!(w, 400);
        assert_eq!(h, 300);
        let decoded = image::load_from_memory(&webp_bytes).expect("decode webp");
        assert_eq!(decoded.width(), 400);
        assert_eq!(decoded.height(), 300);
    }

    #[test]
    fn small_tier_encodes_smaller_than_balanced() {
        // Solid colors compress trivially at any quality — use a larger
        // image with varied content to make the quality difference visible.
        // Checkerboard pattern: two interleaved colors.
        let mut buf = image::RgbaImage::new(256, 256);
        for (x, y, pixel) in buf.enumerate_pixels_mut() {
            let v = ((x ^ y) & 0xff) as u8;
            *pixel = image::Rgba([v, v.wrapping_mul(3), v.wrapping_add(128), 255]);
        }
        let mut png = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut png);
        buf.write_to(&mut cursor, image::ImageFormat::Png)
            .expect("encode png");

        let (balanced, _, _) =
            convert_to_webp_with_quality(&png, WebpQuality::Balanced).expect("balanced");
        let (small, _, _) =
            convert_to_webp_with_quality(&png, WebpQuality::Small).expect("small");
        // Q=30 should produce a smaller (or equal) file than Q=50.
        assert!(
            small.len() <= balanced.len(),
            "Q=30 ({} bytes) should be <= Q=50 ({} bytes)",
            small.len(),
            balanced.len()
        );
    }

    /// Build a minimal 2-frame animated GIF in memory for test input.
    fn make_test_gif(w: u32, h: u32) -> Vec<u8> {
        use image::codecs::gif::GifEncoder;
        use image::{Delay, Frame, Rgba, RgbaImage};

        let frame1 = RgbaImage::from_pixel(w, h, Rgba([255, 0, 0, 255]));
        let frame2 = RgbaImage::from_pixel(w, h, Rgba([0, 0, 255, 255]));

        let mut buf = Vec::new();
        {
            let mut encoder = GifEncoder::new(&mut buf);
            encoder
                .set_repeat(image::codecs::gif::Repeat::Infinite)
                .unwrap();
            encoder
                .encode_frame(Frame::from_parts(
                    frame1,
                    0,
                    0,
                    Delay::from_numer_denom_ms(100, 1),
                ))
                .unwrap();
            encoder
                .encode_frame(Frame::from_parts(
                    frame2,
                    0,
                    0,
                    Delay::from_numer_denom_ms(100, 1),
                ))
                .unwrap();
        }
        buf
    }

    #[test]
    fn gif_to_animated_webp_balanced() {
        let gif = make_test_gif(64, 48);
        let (webp_bytes, w, h) =
            convert_gif_to_animated_webp(&gif, WebpQuality::Balanced).expect("encode");
        assert_eq!(w, 64);
        assert_eq!(h, 48);
        // WebP magic bytes: starts with "RIFF" ... "WEBP".
        assert!(webp_bytes.len() > 12);
        assert_eq!(&webp_bytes[0..4], b"RIFF");
        assert_eq!(&webp_bytes[8..12], b"WEBP");
    }

    #[test]
    fn gif_to_animated_webp_small() {
        let gif = make_test_gif(64, 48);
        let (webp_bytes, w, h) =
            convert_gif_to_animated_webp(&gif, WebpQuality::Small).expect("encode");
        assert_eq!(w, 64);
        assert_eq!(h, 48);
        assert!(webp_bytes.len() > 12);
        assert_eq!(&webp_bytes[0..4], b"RIFF");
    }

    #[test]
    fn gif_to_animated_webp_lossless() {
        let gif = make_test_gif(64, 48);
        let (webp_bytes, w, h) =
            convert_gif_to_animated_webp(&gif, WebpQuality::Lossless).expect("encode");
        assert_eq!(w, 64);
        assert_eq!(h, 48);
        assert!(webp_bytes.len() > 12);
        assert_eq!(&webp_bytes[0..4], b"RIFF");
        assert_eq!(&webp_bytes[8..12], b"WEBP");
    }

    #[test]
    fn gif_to_animated_webp_rejects_invalid() {
        let result = convert_gif_to_animated_webp(b"not a gif", WebpQuality::Balanced);
        assert!(result.is_err());
    }

    /// Build a 2-frame animated WebP in memory (the GIF proxy's preferred
    /// full-variant format) for the decoder-path test.
    fn make_test_animated_webp(w: u32, h: u32) -> Vec<u8> {
        use image::{Rgba, RgbaImage};
        let mut encoder = webp_animation::Encoder::new((w, h)).unwrap();
        let f1 = RgbaImage::from_pixel(w, h, Rgba([255, 0, 0, 255]));
        let f2 = RgbaImage::from_pixel(w, h, Rgba([0, 0, 255, 255]));
        encoder.add_frame(f1.as_raw(), 0).unwrap();
        encoder.add_frame(f2.as_raw(), 120).unwrap();
        encoder.finalize(240).unwrap().to_vec()
    }

    /// Build a PNG and splice a chunk of `kind` in ahead of the first IDAT,
    /// which is where APNG's `acTL` is required to sit.
    fn png_with_chunk(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let png = make_test_png(8, 8);
        let idat = png
            .windows(4)
            .position(|w| w == b"IDAT")
            .expect("test PNG has an IDAT")
            - 4; // back up over the length field
        let mut chunk = Vec::new();
        chunk.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        chunk.extend_from_slice(kind);
        chunk.extend_from_slice(payload);
        chunk.extend_from_slice(&[0, 0, 0, 0]); // CRC — never checked here
        let mut out = png[..idat].to_vec();
        out.extend_from_slice(&chunk);
        out.extend_from_slice(&png[idat..]);
        out
    }

    /// A person's avatar has to out-resolve the profile card, which paints it
    /// at 110 logical = 165 physical at 1.5x. A server icon does not, and its
    /// still replicates inside the CRDT, so the two edges stay different.
    #[test]
    fn avatar_out_resolves_the_profile_card_and_server_icons_stay_small() {
        assert!(
            AVATAR_DIM >= 165,
            "AVATAR_DIM {AVATAR_DIM} would be upscaled by the 110pt profile card at 1.5x"
        );
        assert!(SERVER_ICON_DIM < AVATAR_DIM);

        let png = make_test_png(400, 260);
        let avatar = process_avatar_image(&png).expect("avatar");
        assert_eq!(get_image_dimensions(&avatar).unwrap(), (AVATAR_DIM, AVATAR_DIM));

        let icon = process_still_avatar(&png, SERVER_ICON_DIM).expect("server icon");
        assert_eq!(
            get_image_dimensions(&icon).unwrap(),
            (SERVER_ICON_DIM, SERVER_ICON_DIM)
        );
    }

    /// A source already at the target edge must not be resampled — Lanczos3
    /// ringing on flat art measurably COSTS bytes (a 224px animated source
    /// encoded 64% larger after a downscale to 184 than it did untouched).
    #[test]
    fn a_source_already_at_the_target_edge_is_not_resampled() {
        let exact = make_test_png(AVATAR_DIM, AVATAR_DIM);
        let out = process_avatar_image(&exact).expect("avatar");
        assert_eq!(get_image_dimensions(&out).unwrap(), (AVATAR_DIM, AVATAR_DIM));
    }

    #[test]
    fn apng_reads_as_animated_and_a_still_png_does_not() {
        // num_frames = 2, num_plays = 0
        let apng = png_with_chunk(b"acTL", &[0, 0, 0, 2, 0, 0, 0, 0]);
        assert!(is_apng(&apng), "acTL before IDAT must read as APNG");
        assert!(is_animated_image(&apng));
        // ...but it is NOT an animated WebP, which is what gates passthrough.
        assert!(!is_animated_webp(&apng));

        let still = make_test_png(8, 8);
        assert!(!is_apng(&still));
        assert!(!is_animated_image(&still));
    }

    /// `acTL` occurring by chance inside compressed pixel data must not count.
    /// Walking chunks by length (rather than searching for the literal bytes)
    /// is what makes that true.
    #[test]
    fn actl_bytes_inside_a_chunk_payload_are_not_an_apng() {
        let decoy = png_with_chunk(b"tEXt", b"note\0acTL and more text");
        assert!(
            !is_apng(&decoy),
            "acTL inside a tEXt payload must not read as APNG"
        );
        assert!(!is_animated_image(&decoy));
    }

    #[test]
    fn animated_webp_and_gif_still_read_as_animated() {
        let webp = make_test_animated_webp(16, 16);
        assert!(is_animated_webp(&webp));
        assert!(is_animated_image(&webp));

        let gif = make_test_gif(16, 16);
        assert!(is_animated_image(&gif));
        assert!(!is_animated_webp(&gif), "a GIF is not an animated WebP");

        assert!(!is_animated_image(b"not an image at all"));
        assert!(!is_animated_image(&[]));
    }

    /// An APNG used to upload "successfully" as a frozen first frame. It now
    /// goes through the same decode/re-encode path a GIF does.
    #[test]
    fn server_avatar_anim_accepts_an_apng() {
        let apng = png_with_chunk(b"acTL", &[0, 0, 0, 2, 0, 0, 0, 0]);
        // The decoy PNG has no real fcTL/fdAT frames, so decoding is allowed
        // to fail — what must NOT happen is the old flat "not animated"
        // rejection before the decoder is ever consulted.
        if let Err(e) = process_server_avatar_anim(&apng) {
            assert!(
                !e.contains("Not an animated image"),
                "APNG must reach the decoder, got: {e}"
            );
        }
    }

    #[test]
    fn gif_for_send_reencodes_and_downsizes_gif() {
        let gif = make_test_gif(600, 300);
        let (webp, w, h, animated) = process_gif_for_send(&gif).expect("process");
        assert_eq!(&webp[0..4], b"RIFF");
        assert_eq!(&webp[8..12], b"WEBP");
        assert_eq!((w, h), (480, 240));
        assert!(animated);
        assert!(webp.len() <= 2_097_152);
    }

    #[test]
    fn gif_for_send_reencodes_animated_webp_no_passthrough() {
        let src = make_test_animated_webp(600, 600);
        let (webp, w, h, animated) = process_gif_for_send(&src).expect("process");
        // Re-encoded, never passed through: dims must have shrunk to the cap.
        assert_eq!((w, h), (480, 480));
        assert!(animated);
        assert_eq!(&webp[0..4], b"RIFF");
    }

    #[test]
    fn gif_for_send_small_input_keeps_dims() {
        let src = make_test_animated_webp(200, 100);
        let (_, w, h, animated) = process_gif_for_send(&src).expect("process");
        assert_eq!((w, h), (200, 100));
        assert!(animated);
    }

    #[test]
    fn gif_for_send_still_input_is_single_frame() {
        let png = make_test_png(700, 350);
        let (webp, w, h, animated) = process_gif_for_send(&png).expect("process");
        assert_eq!((w, h), (480, 240));
        assert!(!animated);
        assert_eq!(&webp[0..4], b"RIFF");
    }

    #[test]
    fn gif_for_send_rejects_garbage() {
        assert!(process_gif_for_send(b"definitely not an image").is_err());
    }

    // ── Stickers ──────────────────────────────────────────────────────

    #[test]
    fn sticker_for_send_fits_its_own_box_and_cap() {
        let png = make_test_png(1400, 700);
        let (webp, w, h, animated) = process_sticker_for_send(&png).expect("process");
        // 512, not the GIF pipeline's 480 — same helper, different bounds.
        assert_eq!((w, h), (512, 256));
        assert!(!animated);
        assert_eq!(&webp[0..4], b"RIFF");
        assert!(
            webp.len() <= crate::node::assets::AssetKind::Sticker.recv_cap(),
            "authoring must land under the kind's receipt cap, else it could \
             never be pulled back: {} bytes",
            webp.len()
        );
    }

    #[test]
    fn sticker_for_send_never_upscales() {
        let png = make_test_png(200, 120);
        let (_, w, h, _) = process_sticker_for_send(&png).expect("process");
        assert_eq!((w, h), (200, 120));
    }

    /// The one that matters: a cut-out must still be a cut-out afterwards.
    /// Decoded through `webp_animation` — `image::load_from_memory` reports
    /// 255 for every pixel of an ANMF container (see the fn doc).
    #[test]
    fn sticker_keeps_its_cut_out() {
        let png = make_cutout_png(256, 256);
        let (webp, w, h, _) = process_sticker_for_send(&png).expect("process");
        assert_eq!((w, h), (256, 256));
        assert_eq!(alpha_at(&webp, 4, 4, w), 0, "transparent half must stay transparent");
        assert_eq!(alpha_at(&webp, w - 4, 4, w), 255, "opaque half must stay opaque");
    }

    #[test]
    fn animated_sticker_stays_animated_and_bounded() {
        let src = make_test_animated_webp(900, 900);
        let (webp, w, h, animated) = process_sticker_for_send(&src).expect("process");
        assert_eq!((w, h), (512, 512));
        assert!(animated);
        assert!(webp.len() <= crate::node::assets::AssetKind::Sticker.recv_cap());
    }

    #[test]
    fn sticker_for_send_rejects_garbage() {
        let err = process_sticker_for_send(b"not an image").expect_err("must fail");
        // The label must name what the USER picked, not the shared helper.
        assert!(!err.contains("GIF"), "got: {err}");
    }

    // ── `.hollow-pack` import validation (issue #36) ──────────────────

    #[test]
    fn validate_accepts_what_we_encode_and_reports_true_dims() {
        // A still and an animation must both round-trip, and the dims must
        // come from the DECODE — a pack manifest never gets to assert them.
        let (still, w, h, _) =
            process_sticker_for_send(&make_cutout_png(300, 200)).expect("process");
        assert_eq!(validate_sticker_blob(&still), Ok((w, h, false)));

        let (anim, aw, ah, _) =
            process_sticker_for_send(&make_test_animated_webp(400, 400)).expect("process");
        assert_eq!(validate_sticker_blob(&anim), Ok((aw, ah, true)));
    }

    #[test]
    fn validate_rejects_non_webp_and_garbage() {
        assert!(validate_sticker_blob(b"not an image").is_err());
        assert!(validate_sticker_blob(&[]).is_err());
        // A PNG is a perfectly good image and still not a sticker blob —
        // accepting one would put un-sanitized bytes on the asset rail.
        assert!(validate_sticker_blob(&make_test_png(64, 64)).is_err());
    }

    #[test]
    fn validate_rejects_oversized_bytes() {
        // Over the AssetKind::Sticker receipt cap: refuse before decoding, so
        // a decompression bomb never gets a decoder pointed at it.
        let mut fake = b"RIFF____WEBP".to_vec();
        fake.resize(524_289, 0);
        let err = validate_sticker_blob(&fake).expect_err("must fail");
        assert!(err.contains("512 KB"), "got: {err}");
    }
}

/// Convert a WebP file to another format (for "Save As").
pub fn convert_from_webp(
    data: &[u8],
    target_format: &str,
) -> Result<Vec<u8>, String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode image: {e}"))?;

    let format = match target_format.to_lowercase().as_str() {
        "png" => ImageFormat::Png,
        "jpg" | "jpeg" => ImageFormat::Jpeg,
        "bmp" => ImageFormat::Bmp,
        "gif" => ImageFormat::Gif,
        _ => return Err(format!("Unsupported target format: {target_format}")),
    };

    let mut buf = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut buf);

    img.write_to(&mut cursor, format)
        .map_err(|e| format!("Failed to convert image: {e}"))?;

    Ok(buf)
}

/// A person's avatar, stored and rendered edge.
///
/// The profile card paints the avatar at 110 LOGICAL pixels
/// (`profile_card_body.dart`), which is 165 physical on a 1.5x display and 220
/// on a 2x one — so the old 128 was already being upscaled on the surface that
/// shows an avatar largest. 184 is also exactly a Steam avatar's native size,
/// which is where most animated uploads come from, so the common case now
/// needs no resampling at all.
pub const AVATAR_DIM: u32 = 184;

/// A server's still icon. Servers render far smaller than a profile card (the
/// strip is ~48px), and this one is base64 INSIDE the CRDT rather than on the
/// asset rail, so every extra kilobyte replicates to every member.
pub const SERVER_ICON_DIM: u32 = 128;

/// Process a raw image into a person's avatar: centre-crop square, resize to
/// [`AVATAR_DIM`], encode as WebP.
pub fn process_avatar_image(data: &[u8]) -> Result<Vec<u8>, String> {
    process_still_avatar(data, AVATAR_DIM)
}

/// The same, at an explicit edge. Server icons pass [`SERVER_ICON_DIM`].
pub fn process_still_avatar(data: &[u8], dim: u32) -> Result<Vec<u8>, String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode image: {e}"))?;

    let (w, h) = (img.width(), img.height());
    if w == 0 || h == 0 {
        return Err("Image has zero dimensions".into());
    }
    let side = w.min(h);
    let x = (w - side) / 2;
    let y = (h - side) / 2;

    let cropped = img.crop_imm(x, y, side, side);
    // Skip the resample when the crop is already the target: resizing flat art
    // manufactures intermediate colours that cost real bytes, and a Steam
    // avatar arrives at exactly AVATAR_DIM.
    let rgba = if side == dim {
        cropped.to_rgba8()
    } else {
        cropped.resize_exact(dim, dim, FilterType::Lanczos3).to_rgba8()
    };

    // Lossy, like the showcase encoders: lossless WebP size is
    // content-dependent, so photographic avatars randomly blew the cap.
    let buf = encode_lossy_webp_via_animation(rgba.as_raw(), dim, dim, 80.0)?;

    if buf.len() > 100_000 {
        return Err("Avatar image too large after processing (>100KB)".into());
    }

    Ok(buf)
}

/// Resize an existing avatar to a 64x64 thumbnail for public channel sync responses.
pub fn process_sync_avatar(data: &[u8]) -> Result<Vec<u8>, String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode avatar for sync: {e}"))?;
    let resized = img.resize_exact(64, 64, FilterType::Lanczos3);
    let mut buf = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut buf);
    resized
        .write_to(&mut cursor, ImageFormat::WebP)
        .map_err(|e| format!("Failed to encode sync avatar: {e}"))?;
    Ok(buf)
}

/// Process an IGDB game cover for the showcase board: keep aspect (covers are
/// ~3:4), cap the longest side at 400px, encode as WebP.
pub fn process_showcase_cover(data: &[u8]) -> Result<Vec<u8>, String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode cover: {e}"))?;
    let resized = if img.width().max(img.height()) > 400 {
        img.resize(400, 400, FilterType::Lanczos3)
    } else {
        img
    };
    // Lossy encode (alpha survives — logos stay transparent). NEVER the
    // `image` crate's lossless WebP here: lossless size is content-dependent,
    // so noisy/photographic covers randomly blew the size cap and FAILED
    // SILENTLY at authoring while flat cartoon art sailed through.
    let rgba = resized.to_rgba8();
    let (w, h) = (rgba.width(), rgba.height());
    let buf = encode_lossy_webp_via_animation(rgba.as_raw(), w, h, 75.0)?;
    if buf.len() > 150_000 {
        return Err("Cover too large after processing (>150KB)".into());
    }
    Ok(buf)
}

/// Process user-uploaded showcase artwork: animated GIFs become animated
/// WebP (Balanced), stills keep their aspect capped at 800px on the longest
/// side. Per-asset ceiling keeps the replicated bundle sane.
pub fn process_showcase_artwork(data: &[u8]) -> Result<Vec<u8>, String> {
    if data.starts_with(b"GIF8") {
        let (webp, _w, _h) = convert_gif_to_animated_webp(data, WebpQuality::Balanced)?;
        if webp.len() > 600_000 {
            return Err("Animated artwork too large after processing (>600KB)".into());
        }
        return Ok(webp);
    }
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode artwork: {e}"))?;
    let resized = if img.width().max(img.height()) > 800 {
        img.resize(800, 800, FilterType::Lanczos3)
    } else {
        img
    };
    // Lossy for the same reason as covers: lossless WebP size is
    // content-dependent and busts the cap on noisy images.
    let rgba = resized.to_rgba8();
    let (w, h) = (rgba.width(), rgba.height());
    let buf = encode_lossy_webp_via_animation(rgba.as_raw(), w, h, 75.0)?;
    if buf.len() > 400_000 {
        return Err("Artwork too large after processing (>400KB)".into());
    }
    Ok(buf)
}

/// Process a raw image into a custom emote (content-addressed WebP):
/// - animated GIF → animated WebP, frames resized to ≤64px, Q=75, ≤256KB;
/// - already-animated WebP → accepted AS-IS under the same cap (the image
///   crate can't re-encode animation; the container/magic + first-frame
///   decode are still verified);
/// - anything else → still ≤64px lossy WebP Q=90, ≤32KB.
///
/// Returns `(webp_bytes, animated)`.
pub fn process_emote_image(data: &[u8]) -> Result<(Vec<u8>, bool), String> {
    const MAX_DIM: u32 = 64;
    const MAX_STILL: usize = 32_000;
    const MAX_ANIMATED: usize = 262_144;

    if data.starts_with(b"GIF8") {
        let decoder = GifDecoder::new(Cursor::new(data))
            .map_err(|e| format!("Failed to decode GIF: {e}"))?;
        let frames = decoder
            .into_frames()
            .collect_frames()
            .map_err(|e| format!("Failed to collect GIF frames: {e}"))?;
        if frames.is_empty() {
            return Err("GIF has no frames".into());
        }
        let (w, h) = (frames[0].buffer().width(), frames[0].buffer().height());
        if w == 0 || h == 0 {
            return Err("GIF has zero dimensions".into());
        }
        let (nw, nh) = if w.max(h) > MAX_DIM {
            let scale = MAX_DIM as f32 / w.max(h) as f32;
            (
                ((w as f32 * scale).max(1.0)) as u32,
                ((h as f32 * scale).max(1.0)) as u32,
            )
        } else {
            (w, h)
        };
        let timed: Vec<(image::RgbaImage, i32)> = frames
            .into_iter()
            .map(|f| {
                let delay: std::time::Duration = f.delay().into();
                let ms = delay.as_millis() as i32;
                (f.into_buffer(), if ms < 20 { 100 } else { ms })
            })
            .collect();
        let scaled = crop_resize_frames(&timed, (0, 0, w, h), nw, nh);
        let webp =
            webp_anim::encode_animation(&scaled, (nw, nh), &webp_anim::AnimParams::art(75.0))?;
        if webp.len() > MAX_ANIMATED {
            return Err("Animated emote too large after processing (>256KB)".into());
        }
        return Ok((webp, true));
    }

    // Animated WebP passthrough (verify container + first-frame decode + cap).
    if data.len() > 20
        && &data[0..4] == b"RIFF"
        && &data[8..12] == b"WEBP"
        && &data[12..16] == b"VP8X"
        && (data[20] & 0x02) != 0
    {
        if data.len() > MAX_ANIMATED {
            return Err("Animated emote too large (>256KB)".into());
        }
        image::load_from_memory(data)
            .map_err(|e| format!("Failed to decode animated WebP: {e}"))?;
        return Ok((data.to_vec(), true));
    }

    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode emote image: {e}"))?;
    let (w, h) = (img.width(), img.height());
    if w == 0 || h == 0 {
        return Err("Image has zero dimensions".into());
    }
    let resized = if w.max(h) > MAX_DIM {
        img.resize(MAX_DIM, MAX_DIM, FilterType::Lanczos3)
    } else {
        img
    };
    let rgba = resized.to_rgba8();
    let (ew, eh) = (rgba.width(), rgba.height());
    let buf = encode_lossy_webp_via_animation(rgba.as_raw(), ew, eh, 90.0)?;
    if buf.len() > MAX_STILL {
        return Err("Emote too large after processing (>32KB)".into());
    }
    Ok((buf, false))
}

/// Process a raw image into banner format: center-crop to 3:1 aspect, resize to 600x200, encode as WebP.
/// Accepts any image — crops the widest 3:1 region it can find, or stretches if very small.
pub fn process_banner_image(data: &[u8]) -> Result<Vec<u8>, String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode image: {e}"))?;

    let (w, h) = (img.width(), img.height());
    if w == 0 || h == 0 {
        return Err("Image has zero dimensions".into());
    }

    // Target aspect 3:1 — crop the largest 3:1 region from center
    let (cw, ch) = if w >= h * 3 {
        // Image is wider than 3:1 — crop width
        (h * 3, h)
    } else {
        // Image is taller than 3:1 — crop height
        (w, (w / 3).max(1))
    };
    let x = (w - cw) / 2;
    let y = (h - ch) / 2;

    let cropped = img.crop_imm(x, y, cw, ch);
    let resized = cropped.resize_exact(600, 200, FilterType::Lanczos3);

    // Lossy for the same reason as avatars/covers: lossless size is
    // content-dependent, so photographic banners randomly failed to upload.
    let rgba = resized.to_rgba8();
    let buf = encode_lossy_webp_via_animation(rgba.as_raw(), 600, 200, 80.0)?;

    if buf.len() > 200_000 {
        return Err("Banner image too large after processing (>200KB)".into());
    }

    Ok(buf)
}

/// Process a raw image into a SERVER banner (content-addressed asset,
/// `AssetKind::Banner`): 3:1 center crop → 960x320.
/// - animated GIF → per-frame cropped/resized animated WebP, Q=80, ≤1MB;
/// - already-animated WebP → accepted AS-IS under the 1MB cap (the image
///   crate can't re-encode animation; container magic + first-frame decode
///   are still verified — rendering uses BoxFit.cover, so a non-3:1 source
///   is a visual crop, not an error);
/// - anything else → still 960x320 lossy WebP Q=80, ≤150KB.
///
/// Returns `(webp_bytes, animated)`.
pub fn process_server_banner_image(data: &[u8]) -> Result<(Vec<u8>, bool), String> {
    const BANNER_W: u32 = 960;
    const BANNER_H: u32 = 320;
    const MAX_STILL: usize = 150_000;
    const MAX_ANIMATED: usize = 1_048_576;

    // Largest centered 3:1 region of a (w, h) canvas.
    fn crop_rect_3to1(w: u32, h: u32) -> (u32, u32, u32, u32) {
        let (cw, ch) = if w >= h * 3 {
            (h * 3, h)
        } else {
            (w, (w / 3).max(1))
        };
        ((w - cw) / 2, (h - ch) / 2, cw, ch)
    }

    if data.starts_with(b"GIF8") {
        let decoder = GifDecoder::new(Cursor::new(data))
            .map_err(|e| format!("Failed to decode GIF: {e}"))?;
        let frames = decoder
            .into_frames()
            .collect_frames()
            .map_err(|e| format!("Failed to collect GIF frames: {e}"))?;
        if frames.is_empty() {
            return Err("GIF has no frames".into());
        }
        let (w, h) = (frames[0].buffer().width(), frames[0].buffer().height());
        if w == 0 || h == 0 {
            return Err("GIF has zero dimensions".into());
        }
        let crop = crop_rect_3to1(w, h);
        let timed: Vec<(image::RgbaImage, i32)> = frames
            .into_iter()
            .map(|f| {
                let delay: std::time::Duration = f.delay().into();
                let ms = delay.as_millis() as i32;
                (f.into_buffer(), if ms < 20 { 100 } else { ms })
            })
            .collect();
        let scaled = crop_resize_frames(&timed, crop, BANNER_W, BANNER_H);
        let webp = webp_anim::encode_animation(
            &scaled,
            (BANNER_W, BANNER_H),
            &webp_anim::AnimParams::art(80.0),
        )?;
        if webp.len() > MAX_ANIMATED {
            return Err("Animated banner too large after processing (>1MB)".into());
        }
        return Ok((webp, true));
    }

    // Animated WebP passthrough (verify container + first-frame decode + cap).
    if data.len() > 20
        && &data[0..4] == b"RIFF"
        && &data[8..12] == b"WEBP"
        && &data[12..16] == b"VP8X"
        && (data[20] & 0x02) != 0
    {
        if data.len() > MAX_ANIMATED {
            return Err("Animated banner too large (>1MB)".into());
        }
        image::load_from_memory(data)
            .map_err(|e| format!("Failed to decode animated WebP: {e}"))?;
        return Ok((data.to_vec(), true));
    }

    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode banner image: {e}"))?;
    let (w, h) = (img.width(), img.height());
    if w == 0 || h == 0 {
        return Err("Image has zero dimensions".into());
    }
    let (x, y, cw, ch) = crop_rect_3to1(w, h);
    let cropped = img.crop_imm(x, y, cw, ch);
    let resized = cropped.resize_exact(BANNER_W, BANNER_H, FilterType::Lanczos3);
    let rgba = resized.to_rgba8();
    let buf = encode_lossy_webp_via_animation(rgba.as_raw(), BANNER_W, BANNER_H, 80.0)?;
    if buf.len() > MAX_STILL {
        return Err("Banner image too large after processing (>150KB)".into());
    }
    Ok((buf, false))
}

/// Downscale a stored server banner to a 400x133 still thumbnail for the
/// public-browse wire path (sent to strangers pre-join — never the full
/// blob). Animated banners contribute their first frame.
pub fn process_server_banner_thumb(data: &[u8]) -> Result<Vec<u8>, String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode banner for thumb: {e}"))?;
    let (w, h) = (img.width(), img.height());
    if w == 0 || h == 0 {
        return Err("Banner has zero dimensions".into());
    }
    // Same 3:1 center crop as authoring — a passthrough animated WebP may
    // not be 3:1, and the thumb must match what BoxFit.cover shows.
    let (cw, ch) = if w >= h * 3 { (h * 3, h) } else { (w, (w / 3).max(1)) };
    let cropped = img.crop_imm((w - cw) / 2, (h - ch) / 2, cw, ch);
    let resized = cropped.resize_exact(400, 133, FilterType::Lanczos3);
    let rgba = resized.to_rgba8();
    let buf = encode_lossy_webp_via_animation(rgba.as_raw(), 400, 133, 75.0)?;
    if buf.len() > 40_000 {
        return Err("Banner thumb too large (>40KB)".into());
    }
    Ok(buf)
}

/// True when the raw bytes are an animated source: a GIF, a WebP whose VP8X
/// header carries the animation flag, or a PNG carrying an `acTL` chunk
/// (APNG). Gates the animated-icon split in `set_server_avatar` (still inputs
/// never touch the asset rail).
///
/// Decided from BYTES, never a filename. `isAnimatedImageBytes` in
/// `animated_gif_image.dart` mirrors this exactly, because the avatar picker
/// used to branch on a `.gif` extension and therefore sent animated WebP and
/// APNG through the still cropper, which rasterised them to a frozen PNG with
/// no error shown.
pub fn is_animated_image(data: &[u8]) -> bool {
    data.starts_with(b"GIF8") || is_animated_webp(data) || is_apng(data)
}

/// True only for a WebP whose VP8X header carries the animation flag.
///
/// Distinct from [`is_animated_image`] on purpose: the passthrough and
/// decode branches below ask "is this ALREADY an animated WebP I can hand to
/// the WebP decoder or store untouched", which is a narrower question than
/// "does this move". Answering the broad question at those sites would route
/// a GIF or an APNG into the WebP decoder and store a non-WebP blob on a rail
/// whose readers all assume WebP.
pub fn is_animated_webp(data: &[u8]) -> bool {
    data.len() > 20
        && &data[0..4] == b"RIFF"
        && &data[8..12] == b"WEBP"
        && &data[12..16] == b"VP8X"
        && (data[20] & 0x02) != 0
}

/// True for a PNG that carries an `acTL` (animation control) chunk.
///
/// APNG puts `acTL` before the first `IDAT`, so the scan stops there rather
/// than walking a whole multi-megabyte file. Chunks are walked properly by
/// length rather than searched for the literal bytes, since `acTL` can occur
/// inside compressed pixel data by chance.
fn is_apng(data: &[u8]) -> bool {
    const SIG: usize = 8; // PNG signature
    if data.len() < SIG + 12 || !data.starts_with(b"\x89PNG\r\n\x1a\n") {
        return false;
    }
    let mut i = SIG;
    // Each chunk: 4-byte length, 4-byte type, payload, 4-byte CRC.
    while i + 8 <= data.len() {
        let len = u32::from_be_bytes([data[i], data[i + 1], data[i + 2], data[i + 3]]) as usize;
        let kind = &data[i + 4..i + 8];
        if kind == b"acTL" {
            return true;
        }
        // acTL is required to precede IDAT, so anything past here is pixels.
        if kind == b"IEND" || kind == b"IDAT" {
            return false;
        }
        match i.checked_add(12).and_then(|n| n.checked_add(len)) {
            Some(next) => i = next,
            None => return false, // length overflow: malformed
        }
    }
    false
}

/// Validate an ALREADY-ENCODED sticker blob and report its true
/// `(width, height, animated)`. For `.hollow-pack` imports.
///
/// Deliberately does NOT re-encode. A sticker's identity is the SHA-256 of
/// its bytes, so re-encoding would mint a different hash and orphan every
/// `[a:s:hash:w:h]` token already sent against the original — the blob has to
/// round-trip byte-identically or it is not the same sticker.
///
/// That makes this the whole trust boundary for imported bytes, so it is
/// strict: WebP container magic, the `AssetKind::Sticker` receipt cap, a real
/// decode, and dimensions read out of the DECODED image rather than taken
/// from the manifest. A manifest that lies about w/h is a layout bomb — those
/// two numbers go straight into the wire token.
pub fn validate_sticker_blob(data: &[u8]) -> Result<(u32, u32, bool), String> {
    const MAX_STICKER_BYTES: usize = 524_288; // == AssetKind::Sticker recv_cap
    const MAX_FRAMES: usize = 300;

    if data.len() > MAX_STICKER_BYTES {
        return Err("Sticker is over the 512 KB limit".into());
    }
    if data.len() < 16 || &data[0..4] != b"RIFF" || &data[8..12] != b"WEBP" {
        return Err("Sticker is not a WebP image".into());
    }

    // Everything Hollow emits is an ANMF container even for a still, so the
    // animation decoder is the common path; a plain still WebP from some
    // other producer falls back to the image crate.
    let (w, h, frames) = match webp_animation::Decoder::new(data) {
        Ok(decoder) => {
            let mut dims: Option<(u32, u32)> = None;
            let mut frames = 0usize;
            for frame in decoder.into_iter() {
                frames += 1;
                if frames > MAX_FRAMES {
                    return Err("Sticker has too many frames".into());
                }
                if dims.is_none() {
                    dims = Some(frame.dimensions());
                }
            }
            let (w, h) = dims.ok_or("Sticker has no frames")?;
            (w, h, frames)
        }
        Err(_) => {
            let img = image::load_from_memory(data)
                .map_err(|e| format!("Sticker failed to decode: {e}"))?;
            (img.width(), img.height(), 1)
        }
    };

    if w == 0 || h == 0 {
        return Err("Sticker has zero dimensions".into());
    }
    // The authoring bound, re-checked: an oversized sticker would render at
    // its own pixels and blow past the chat box.
    if w > 512 || h > 512 {
        return Err("Sticker is over 512px".into());
    }
    Ok((w, h, frames > 1))
}

/// Process an animated source into the ANIMATED server-icon variant
/// (content-addressed asset, `AssetKind::Avatar`): square center crop →
/// 128x128.
/// - animated WebP already at or under 128px → accepted AS-IS under the
///   512KB cap (no second generation of loss, and the content hash survives);
/// - anything else animated (GIF, APNG, an oversized animated WebP) →
///   decoded, centre-cropped square, resized and re-encoded at Q=80, ≤512KB.
///
/// The still companion in `settings["server_avatar"]` comes from
/// `process_avatar_image` (frame 0) — this produces ONLY the animated blob.
pub fn process_server_avatar_anim(data: &[u8]) -> Result<Vec<u8>, String> {
    const ICON_DIM: u32 = 128;
    const MAX_ANIMATED: usize = 524_288;

    // Largest centered square of a (w, h) canvas.
    fn crop_rect_square(w: u32, h: u32) -> (u32, u32, u32, u32) {
        let side = w.min(h);
        ((w - side) / 2, (h - side) / 2, side, side)
    }

    // Already an animated WebP at or under the icon size: pass the bytes
    // through untouched. Re-encoding here would only add a generation of
    // loss, and a content-addressed blob that survives byte-identically
    // keeps its hash across a re-upload.
    if is_animated_webp(data) {
        if data.len() > MAX_ANIMATED {
            return Err("Animated icon too large (>512KB)".into());
        }
        let (w, h) = get_image_dimensions(data)?;
        if w <= ICON_DIM && h <= ICON_DIM {
            return Ok(data.to_vec());
        }
        // Oversized: fall through and re-encode down to ICON_DIM rather than
        // storing a blob every reader then has to downscale at paint time.
    }

    // Everything animated we can decode — GIF, APNG, or an oversized animated
    // WebP — goes through one path: decode, centre-crop square, resize, encode.
    let frames = decode_animation_frames(data)?;
    let (w, h) = (frames[0].0.width(), frames[0].0.height());
    if w == 0 || h == 0 {
        return Err("Animation has zero dimensions".into());
    }
    let scaled = crop_resize_frames(&frames, crop_rect_square(w, h), ICON_DIM, ICON_DIM);
    let webp = webp_anim::encode_animation(
        &scaled,
        (ICON_DIM, ICON_DIM),
        &webp_anim::AnimParams::art(80.0),
    )?;
    if webp.len() > MAX_ANIMATED {
        return Err("Animated icon too large after processing (>512KB)".into());
    }
    Ok(webp)
}

/// Encode pre-sized RGBA frames (frame, duration-ms) as a lossy animated WebP
/// at the ART preset — every caller is user-uploaded artwork.
fn encode_animation_frames(
    frames: &[(image::RgbaImage, i32)],
    dims: (u32, u32),
    quality: f32,
) -> Result<Vec<u8>, String> {
    webp_anim::encode_animation(frames, dims, &webp_anim::AnimParams::art(quality))
}

/// Process a picked GIF (downloaded from the GIF proxy's `full` variant) into
/// the send format: ≤480px animated WebP, ≤2 MB (== `AssetKind::Gif` receipt
/// cap).
///
/// Returns `(webp_bytes, width, height, animated)` of the encoded asset.
pub fn process_gif_for_send(data: &[u8]) -> Result<(Vec<u8>, u32, u32, bool), String> {
    // Quality drops first (cheap wins), then dimensions.
    const LADDER: [(u32, f32); 4] = [(480, 80.0), (480, 65.0), (400, 55.0), (320, 45.0)];
    process_asset_for_send(data, 480, 2_097_152, &LADDER, "GIF")
}

/// Process a sticker — an upload the user picked, or a Klipy sticker's source
/// — into the send format: ≤512px animated WebP, ≤512 KB (==
/// `AssetKind::Sticker` receipt cap).
///
/// Stickers lean harder on quality than GIFs do (they ARE the message, and
/// they are usually flat art that compresses well), so the ladder starts at
/// Q85 and only then walks down.
///
/// TRANSPARENCY SURVIVES, and that is load-bearing — a cut-out matted onto
/// black is a visible defect, not a nuance. libwebp carries alpha in its own
/// plane at `alpha_quality: 100` by default, and
/// [encode_lossy_webp_via_animation] keeps those defaults.
///
/// One trap when verifying that: every asset this module emits is a WebP
/// ANIMATION container (`ANMF`), even a single-frame still — deliberate, so
/// only one libwebp-sys variant links into the binary. The `image` crate's
/// WebP decoder reports alpha 255 for those, so a test that checks alpha via
/// `image::load_from_memory` will "fail" on perfectly good bytes. Decode
/// with `webp_animation::Decoder` (what Skia effectively does on the Flutter
/// side) — see `sticker_keeps_its_cut_out`.
///
/// Returns `(webp_bytes, width, height, animated)` of the encoded asset.
pub fn process_sticker_for_send(data: &[u8]) -> Result<(Vec<u8>, u32, u32, bool), String> {
    const LADDER: [(u32, f32); 5] = [
        (512, 85.0),
        (512, 70.0),
        (448, 60.0),
        (384, 50.0),
        (320, 45.0),
    ];
    process_asset_for_send(data, 512, 524_288, &LADDER, "Sticker")
}

/// Shared transcode for the block-rendered asset kinds (GIFs, stickers).
///
/// Unlike the emote/icon paths there is NO animated-WebP passthrough: the
/// sources these are fed (a GIF proxy's hd-slot WebP, an arbitrary user
/// upload) routinely exceed both bounds — and re-encoding at authoring IS the
/// sanitization step. Animated WebP decodes via `webp_animation::Decoder`,
/// GIF via the image crate; frames are resized DURING decode so
/// source-resolution frames are never all held at once. `ladder` is walked in
/// order until an encode fits `max_bytes`; `label` names the kind in error
/// messages the user will actually read.
fn process_asset_for_send(
    data: &[u8],
    max_dim: u32,
    max_bytes: usize,
    ladder: &[(u32, f32)],
    label: &str,
) -> Result<(Vec<u8>, u32, u32, bool), String> {
    const MAX_FRAMES: usize = 300;

    fn fit_dims(w: u32, h: u32, max_dim: u32) -> (u32, u32) {
        if w.max(h) > max_dim {
            let scale = max_dim as f32 / w.max(h) as f32;
            (
                ((w as f32 * scale).max(1.0)) as u32,
                ((h as f32 * scale).max(1.0)) as u32,
            )
        } else {
            (w, h)
        }
    }

    let mut frames: Vec<(image::RgbaImage, i32)> = Vec::new();
    let mut target: Option<(u32, u32)> = None;

    if data.starts_with(b"GIF8") {
        let decoder = GifDecoder::new(Cursor::new(data))
            .map_err(|e| format!("Failed to decode GIF: {e}"))?;
        for frame in decoder.into_frames() {
            let frame = frame.map_err(|e| format!("Failed to decode GIF frame: {e}"))?;
            if frames.len() >= MAX_FRAMES {
                return Err(format!("{label} is too long to send"));
            }
            let (w, h) = (frame.buffer().width(), frame.buffer().height());
            if w == 0 || h == 0 {
                return Err("GIF has zero dimensions".into());
            }
            let (nw, nh) = *target.get_or_insert_with(|| fit_dims(w, h, max_dim));
            let rgba = if (w, h) != (nw, nh) {
                image::imageops::resize(frame.buffer(), nw, nh, FilterType::Lanczos3)
            } else {
                frame.buffer().clone()
            };
            let delay: std::time::Duration = frame.delay().into();
            let delay_ms = delay.as_millis() as i32;
            frames.push((rgba, if delay_ms < 20 { 100 } else { delay_ms }));
        }
    } else if is_animated_webp(data) {
        let decoder = webp_animation::Decoder::new(data)
            .map_err(|e| format!("Failed to decode animated WebP: {e:?}"))?;
        // Decoder timestamps are cumulative end-of-frame times.
        let mut prev_ts: i32 = 0;
        for frame in decoder.into_iter() {
            if frames.len() >= MAX_FRAMES {
                return Err(format!("{label} is too long to send"));
            }
            let (w, h) = frame.dimensions();
            if w == 0 || h == 0 {
                return Err("Animated WebP has zero dimensions".into());
            }
            let src = image::RgbaImage::from_raw(w, h, frame.data().to_vec())
                .ok_or("Animated WebP frame has unexpected size")?;
            let (nw, nh) = *target.get_or_insert_with(|| fit_dims(w, h, max_dim));
            let rgba = if (w, h) != (nw, nh) {
                image::imageops::resize(&src, nw, nh, FilterType::Lanczos3)
            } else {
                src
            };
            let duration_ms = (frame.timestamp() - prev_ts).max(1);
            prev_ts = frame.timestamp();
            frames.push((rgba, duration_ms));
        }
    } else {
        // Still source (e.g. a still WebP full variant) — single-frame asset.
        let img = image::load_from_memory(data)
            .map_err(|e| format!("Failed to decode image: {e}"))?;
        let (w, h) = (img.width(), img.height());
        if w == 0 || h == 0 {
            return Err("Image has zero dimensions".into());
        }
        let (nw, nh) = fit_dims(w, h, max_dim);
        let resized = if (w, h) != (nw, nh) {
            img.resize_exact(nw, nh, FilterType::Lanczos3)
        } else {
            img
        };
        frames.push((resized.to_rgba8(), 0));
    }

    if frames.is_empty() {
        return Err(format!("{label} has no frames"));
    }
    let animated = frames.len() > 1;
    let (base_w, base_h) = (frames[0].0.width(), frames[0].0.height());

    for &(rung_dim, quality) in ladder {
        let (nw, nh) = fit_dims(base_w, base_h, rung_dim);
        let scaled;
        let attempt: &[(image::RgbaImage, i32)] = if (nw, nh) != (base_w, base_h) {
            scaled = frames
                .iter()
                .map(|(f, d)| (image::imageops::resize(f, nw, nh, FilterType::Lanczos3), *d))
                .collect::<Vec<_>>();
            &scaled
        } else {
            &frames
        };
        let bytes = if animated {
            encode_animation_frames(attempt, (nw, nh), quality)?
        } else {
            encode_lossy_webp_via_animation(attempt[0].0.as_raw(), nw, nh, quality)?
        };
        if bytes.len() <= max_bytes {
            return Ok((bytes, nw, nh, animated));
        }
    }
    Err(format!(
        "{label} is too large to send even after conversion"
    ))
}


// ── Avatar frames (issue #54) ─────────────────────────────────────────

/// Frame art is 128x128, the same square an avatar is stored at.
const FRAME_DIM: u32 = 128;
/// `AssetKind::Frame` receipt cap. A frame is decoration on every avatar you
/// have ever seen, so it gets the emote ceiling, not the rail's 512 KB.
const MAX_FRAME_ANIMATED_BYTES: usize = 262_144;
/// Stills are held to a quarter of that — there is no animation to pay for.
const MAX_FRAME_STILL_BYTES: usize = 65_536;
/// Diameter of the centre disc the transparency gate samples, as a fraction
/// of the frame box. The avatar fills the middle 1/1.33 = 75% of the box, so
/// a 42% disc sits comfortably inside it: art may hug or cross the avatar's
/// EDGES (which is the whole point of a foreground frame) and only a frame
/// that blocks the middle is refused.
const FRAME_HOLE_DIAMETER: f32 = 0.42;
/// Refuse when more than this fraction of the sampled disc is opaque,
/// averaged over every frame. Averaging is deliberate: a bird that flies
/// across the middle for three frames of thirty is fine, a permanent blob
/// is not.
const FRAME_HOLE_MAX_OPAQUE: f32 = 0.40;
/// Alpha at or above this counts as "you cannot see the avatar here".
const FRAME_HOLE_OPAQUE_ALPHA: u8 = 128;

/// Fraction of the centre disc of `img` that is opaque.
fn frame_centre_opacity(img: &image::RgbaImage) -> f32 {
    let (w, h) = (img.width() as f32, img.height() as f32);
    let radius = w.min(h) * FRAME_HOLE_DIAMETER / 2.0;
    let (cx, cy) = (w / 2.0, h / 2.0);
    let r2 = radius * radius;
    let mut sampled = 0u32;
    let mut opaque = 0u32;
    for (x, y, px) in img.enumerate_pixels() {
        let dx = x as f32 + 0.5 - cx;
        let dy = y as f32 + 0.5 - cy;
        if dx * dx + dy * dy > r2 {
            continue;
        }
        sampled += 1;
        if px.0[3] >= FRAME_HOLE_OPAQUE_ALPHA {
            opaque += 1;
        }
    }
    if sampled == 0 {
        return 0.0;
    }
    opaque as f32 / sampled as f32
}

/// The message a frame with a blocked middle is refused with. Sentence case,
/// no em dashes (user-visible copy rule).
fn frame_hole_error() -> String {
    "The middle of a frame has to be transparent so your avatar shows through".into()
}

/// Largest centred square of a (w, h) canvas.
fn frame_crop_rect(w: u32, h: u32) -> (u32, u32, u32, u32) {
    let side = w.min(h);
    ((w - side) / 2, (h - side) / 2, side, side)
}

/// Process a user-picked image into an AVATAR FRAME blob
/// (content-addressed asset, `AssetKind::Frame`): square centre crop ->
/// 128x128, animated WebP Q80 for GIF / animated-WebP input and a still
/// lossy WebP otherwise. Returns `(bytes, animated)`.
///
/// Frames paint IN FRONT of the avatar, so this also enforces the authoring
/// gate that makes that work: the centre of the box has to be see-through,
/// or the decoration simply hides the thing it decorates. See
/// [`frame_centre_opacity`].
pub fn process_avatar_frame(data: &[u8]) -> Result<(Vec<u8>, bool), String> {
    if data.starts_with(b"GIF8") {
        let decoder = GifDecoder::new(Cursor::new(data))
            .map_err(|e| format!("Failed to decode GIF: {e}"))?;
        let frames = decoder
            .into_frames()
            .collect_frames()
            .map_err(|e| format!("Failed to collect GIF frames: {e}"))?;
        if frames.is_empty() {
            return Err("GIF has no frames".into());
        }
        let (w, h) = (frames[0].buffer().width(), frames[0].buffer().height());
        if w == 0 || h == 0 {
            return Err("GIF has zero dimensions".into());
        }
        let (x, y, cw, ch) = frame_crop_rect(w, h);

        let mut prepared: Vec<(image::RgbaImage, i32)> = Vec::with_capacity(frames.len());
        let mut opacity_sum = 0.0f32;
        for frame in &frames {
            let cropped = image::imageops::crop_imm(frame.buffer(), x, y, cw, ch).to_image();
            let resized =
                image::imageops::resize(&cropped, FRAME_DIM, FRAME_DIM, FilterType::Lanczos3);
            opacity_sum += frame_centre_opacity(&resized);
            let delay: std::time::Duration = frame.delay().into();
            let delay_ms = delay.as_millis() as i32;
            prepared.push((resized, if delay_ms < 20 { 100 } else { delay_ms }));
        }
        if opacity_sum / prepared.len() as f32 > FRAME_HOLE_MAX_OPAQUE {
            return Err(frame_hole_error());
        }

        let webp = encode_animation_frames(&prepared, (FRAME_DIM, FRAME_DIM), 80.0)?;
        if webp.len() > MAX_FRAME_ANIMATED_BYTES {
            return Err("Animated frame is too large after processing (over 256 KB)".into());
        }
        return Ok((webp, true));
    }

    // Animated WebP: the image crate cannot re-encode animation, so the
    // source rides as-is under the cap (same trade as animated server
    // icons). The container is still verified, and every frame is decoded
    // for the transparency gate.
    if is_animated_webp(data) {
        if data.len() > MAX_FRAME_ANIMATED_BYTES {
            return Err("Animated frame is too large (over 256 KB)".into());
        }
        let decoder = webp_animation::Decoder::new(data)
            .map_err(|e| format!("Failed to decode animated WebP: {e}"))?;
        let mut count = 0u32;
        let mut opacity_sum = 0.0f32;
        for frame in decoder.into_iter() {
            let (fw, fh) = frame.dimensions();
            if fw == 0 || fh == 0 {
                return Err("Animated frame has zero dimensions".into());
            }
            let rgba = image::RgbaImage::from_raw(fw, fh, frame.data().to_vec())
                .ok_or("Animated frame has a malformed pixel buffer")?;
            opacity_sum += frame_centre_opacity(&rgba);
            count += 1;
            if count > 300 {
                return Err("Animated frame has too many frames".into());
            }
        }
        if count == 0 {
            return Err("Animated frame has no frames".into());
        }
        if opacity_sum / count as f32 > FRAME_HOLE_MAX_OPAQUE {
            return Err(frame_hole_error());
        }
        return Ok((data.to_vec(), true));
    }

    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode image: {e}"))?;
    let (w, h) = (img.width(), img.height());
    if w == 0 || h == 0 {
        return Err("Image has zero dimensions".into());
    }
    let (x, y, cw, ch) = frame_crop_rect(w, h);
    let resized = img
        .crop_imm(x, y, cw, ch)
        .resize_exact(FRAME_DIM, FRAME_DIM, FilterType::Lanczos3)
        .to_rgba8();
    if frame_centre_opacity(&resized) > FRAME_HOLE_MAX_OPAQUE {
        return Err(frame_hole_error());
    }
    let buf = encode_lossy_webp_via_animation(resized.as_raw(), FRAME_DIM, FRAME_DIM, 80.0)?;
    if buf.len() > MAX_FRAME_STILL_BYTES {
        return Err("Frame is too large after processing (over 64 KB)".into());
    }
    Ok((buf, false))
}
