//! Image conversion utilities — WebP encoding for file sharing, avatars, and banners.

use image::imageops::FilterType;
use image::ImageFormat;

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
    let encoder = webp::Encoder::from_rgba(rgba.as_raw(), ew, eh);
    let webp_mem = encoder.encode(q_value);
    Ok((webp_mem.to_vec(), ew, eh))
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
    let encoder = webp::Encoder::from_rgba(rgba.as_raw(), ew, eh);
    let webp_mem = encoder.encode(50.0); // Q=50 lossy
    Ok((webp_mem.to_vec(), ew, eh))
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

/// Process a raw image into avatar format: center-crop to square, resize to 128x128, encode as WebP.
pub fn process_avatar_image(data: &[u8]) -> Result<Vec<u8>, String> {
    let img = image::load_from_memory(data)
        .map_err(|e| format!("Failed to decode image: {e}"))?;

    let (w, h) = (img.width(), img.height());
    let side = w.min(h);
    let x = (w - side) / 2;
    let y = (h - side) / 2;

    let cropped = img.crop_imm(x, y, side, side);
    let resized = cropped.resize_exact(128, 128, FilterType::Lanczos3);

    let mut buf = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut buf);
    resized
        .write_to(&mut cursor, ImageFormat::WebP)
        .map_err(|e| format!("Failed to encode avatar WebP: {e}"))?;

    if buf.len() > 100_000 {
        return Err("Avatar image too large after processing (>100KB)".into());
    }

    Ok(buf)
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
    let (cw, ch) = if w * 1 >= h * 3 {
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

    let mut buf = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut buf);
    resized
        .write_to(&mut cursor, ImageFormat::WebP)
        .map_err(|e| format!("Failed to encode banner WebP: {e}"))?;

    if buf.len() > 200_000 {
        return Err("Banner image too large after processing (>200KB)".into());
    }

    Ok(buf)
}
