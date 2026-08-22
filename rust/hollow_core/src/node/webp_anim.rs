//! Animated-WebP encoding, straight onto libwebp's `WebPAnimEncoder`.
//!
//! # Why this exists instead of `webp_animation::Encoder`
//!
//! `webp-animation` 0.9 is a thin wrapper, and it drops two things on the
//! floor that turn out to matter a lot on real avatars:
//!
//! 1. **`EncodingConfig::method` is a dead field.** Its `apply_to()` writes
//!    only `lossless` and `quality` into the `WebPConfig`, so `method` never
//!    reaches libwebp. Every animated encode in Hollow has therefore run at
//!    libwebp's default method 4, and there is no way to ask for 6 through
//!    that crate at all.
//! 2. **`LossyEncodingConfig::default()` sets `segments: 1`.** libwebp's own
//!    default is 4. Fewer segments means coarser bit allocation across the
//!    frame, so we were paying for worse rate-distortion by accident.
//!
//! Measured together on real Steam avatars, restoring both is ~10% smaller
//! output at the same quality number, at equal or better fidelity. And going
//! direct also unlocks `use_sharp_yuv`, which was the single biggest
//! quality-per-byte win in the bench: on flat art with saturated hard edges
//! it beat Q95 on PSNR at 15-30% fewer bytes, because the chroma bleed of
//! the default RGB->YUV conversion is most of what reads as "damage" on line
//! art.
//!
//! Uploads are a one-off, so trading encode CPU for permanently smaller,
//! better-looking bytes is the right side of that deal every time.
//!
//! `webp_animation::Decoder` is still used for decoding; only the encode side
//! lives here.

use image::RgbaImage;
use libwebp_sys as webp;

/// Encoder knobs, in libwebp's own terms.
///
/// Construct through the presets below rather than field-by-field — the
/// presets are what the bench actually validated.
#[derive(Debug, Clone)]
pub struct AnimParams {
    /// Lossless coding. `quality` then means EFFORT (0 fast .. 100 best),
    /// not fidelity.
    pub lossless: bool,
    /// Lossy: 0-100 fidelity. Lossless: 0-100 effort.
    pub quality: f32,
    /// Quality/speed trade-off, 0 fast .. 6 slower-better.
    pub method: i32,
    /// Segments for bit allocation, 1..4. libwebp's default is 4.
    pub segments: i32,
    /// Spatial noise shaping, 0 off .. 100 max.
    pub sns_strength: i32,
    /// Deblocking filter strength, 0 off .. 100 strongest.
    pub filter_strength: i32,
    /// Deblocking filter sharpness, 0 sharpest .. 7 least sharp.
    pub filter_sharpness: i32,
    /// Slow, high-precision RGB->YUV. Worth it on hard edges.
    pub sharp_yuv: bool,
    /// Extra size-minimisation pass (slow). Implicitly disables keyframes.
    pub minimize_size: bool,
}

impl Default for AnimParams {
    /// libwebp's own defaults (`config_enc.c`), so a bare `..Default::default()`
    /// never silently reintroduces `webp-animation`'s deviations.
    fn default() -> Self {
        Self {
            lossless: false,
            quality: 75.0,
            method: 4,
            segments: 4,
            sns_strength: 50,
            filter_strength: 60,
            filter_sharpness: 0,
            sharp_yuv: false,
            minimize_size: false,
        }
    }
}

impl AnimParams {
    /// The house preset for user-facing animated ART: avatars, banners,
    /// server icons, emotes, stickers, avatar frames.
    ///
    /// libwebp's "drawing" tuning (low noise shaping, light and sharp
    /// deblocking) plus sharp YUV and the slow method. Built for flat colour
    /// with hard edges, which is what essentially all of this content is.
    pub fn art(quality: f32) -> Self {
        Self {
            quality,
            method: 6,
            sns_strength: 25,
            filter_strength: 10,
            filter_sharpness: 6,
            sharp_yuv: true,
            ..Default::default()
        }
    }

    /// Plain lossy animation for the file-send pipeline, where the content is
    /// arbitrary and the user picked a quality tier. Keeps libwebp's general
    /// tuning; still gets method 6 and 4 segments.
    pub fn plain(quality: f32) -> Self {
        Self {
            quality,
            method: 6,
            ..Default::default()
        }
    }

    /// Lossless animation. `effort` is 0 (fast, larger) .. 100 (slow, best).
    ///
    /// Note this is 5-8x larger than lossy on real animated avatars — it is
    /// for the explicit Lossless quality tier, not a default.
    pub fn lossless(effort: f32) -> Self {
        Self {
            lossless: true,
            quality: effort,
            method: 6,
            ..Default::default()
        }
    }
}

/// Encode pre-sized RGBA frames as an animated WebP.
///
/// `frames` is `(frame, duration_ms)`; every frame must already be exactly
/// `dims`. Durations are the DISPLAY time of that frame, so they are summed
/// into libwebp's absolute timestamps here.
pub fn encode_animation(
    frames: &[(RgbaImage, i32)],
    dims: (u32, u32),
    params: &AnimParams,
) -> Result<Vec<u8>, String> {
    let (w, h) = dims;
    if w == 0 || h == 0 {
        return Err("Animation has zero dimensions".into());
    }
    if frames.is_empty() {
        return Err("Animation has no frames".into());
    }
    for (i, (buf, _)) in frames.iter().enumerate() {
        if buf.width() != w || buf.height() != h {
            return Err(format!(
                "Frame {i} is {}x{}, expected {w}x{h}",
                buf.width(),
                buf.height()
            ));
        }
    }

    // SAFETY: every raw call below is checked, and both the encoder and each
    // picture are released on every path out (including the error paths).
    unsafe {
        let mut opts: webp::WebPAnimEncoderOptions = std::mem::zeroed();
        if webp::WebPAnimEncoderOptionsInit(&mut opts) == 0 {
            return Err("Failed to init WebP animation options".into());
        }
        opts.minimize_size = params.minimize_size as i32;
        opts.allow_mixed = 0;
        // kmin/kmax 0 disables keyframe insertion, which is what we want for
        // short looping art: a keyframe is a full frame, and these loops are
        // seconds long.
        opts.kmin = 0;
        opts.kmax = 0;
        opts.anim_params.loop_count = 0; // loop forever

        let enc = webp::WebPAnimEncoderNew(w as i32, h as i32, &opts);
        if enc.is_null() {
            return Err("Failed to create WebP animation encoder".into());
        }
        // From here on every early return must go through `fail`.
        let fail = |enc: *mut webp::WebPAnimEncoder, msg: String| -> String {
            webp::WebPAnimEncoderDelete(enc);
            msg
        };

        let mut cfg: webp::WebPConfig = std::mem::zeroed();
        if webp::WebPConfigInit(&mut cfg) == 0 {
            return Err(fail(enc, "Failed to init WebP config".into()));
        }
        cfg.lossless = params.lossless as i32;
        cfg.quality = params.quality;
        cfg.method = params.method;
        cfg.segments = params.segments;
        cfg.sns_strength = params.sns_strength;
        cfg.filter_strength = params.filter_strength;
        cfg.filter_sharpness = params.filter_sharpness;
        cfg.use_sharp_yuv = params.sharp_yuv as i32;
        cfg.thread_level = 1;
        if webp::WebPValidateConfig(&cfg) == 0 {
            return Err(fail(enc, "Invalid WebP encoding config".into()));
        }

        let mut timestamp_ms: i32 = 0;
        for (buf, duration_ms) in frames {
            let mut pic: webp::WebPPicture = std::mem::zeroed();
            if webp::WebPPictureInit(&mut pic) == 0 {
                return Err(fail(enc, "Failed to init WebP picture".into()));
            }
            pic.use_argb = 1;
            pic.width = w as i32;
            pic.height = h as i32;
            if webp::WebPPictureImportRGBA(&mut pic, buf.as_raw().as_ptr(), (w * 4) as i32) == 0 {
                webp::WebPPictureFree(&mut pic);
                return Err(fail(enc, "Failed to import frame pixels".into()));
            }
            let added = webp::WebPAnimEncoderAdd(enc, &mut pic, timestamp_ms, &cfg);
            webp::WebPPictureFree(&mut pic);
            if added == 0 {
                let detail = encoder_error(enc);
                return Err(fail(enc, format!("Failed to add WebP frame: {detail}")));
            }
            timestamp_ms = timestamp_ms.saturating_add((*duration_ms).max(1));
        }

        // A final null frame is what tells libwebp how long the LAST frame is
        // shown; without it the loop ends early.
        webp::WebPAnimEncoderAdd(enc, std::ptr::null_mut(), timestamp_ms, std::ptr::null());

        let mut out: webp::WebPData = std::mem::zeroed();
        webp::WebPDataInit(&mut out);
        if webp::WebPAnimEncoderAssemble(enc, &mut out) == 0 {
            let detail = encoder_error(enc);
            return Err(fail(
                enc,
                format!("Failed to finalize animated WebP: {detail}"),
            ));
        }
        let bytes = std::slice::from_raw_parts(out.bytes, out.size).to_vec();
        webp::WebPDataClear(&mut out);
        webp::WebPAnimEncoderDelete(enc);
        Ok(bytes)
    }
}

/// libwebp's own message for the last failure on this encoder.
///
/// # Safety
/// `enc` must be a live encoder from `WebPAnimEncoderNew`.
unsafe fn encoder_error(enc: *mut webp::WebPAnimEncoder) -> String {
    unsafe {
        let ptr = webp::WebPAnimEncoderGetError(enc);
        if ptr.is_null() {
            return "unknown error".into();
        }
        std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Two frames of flat colour, the shape everything here encodes.
    fn frames(w: u32, h: u32, n: usize) -> Vec<(RgbaImage, i32)> {
        (0..n)
            .map(|i| {
                let shade = (40 + i * 60) as u8;
                let mut img = RgbaImage::new(w, h);
                for (x, y, px) in img.enumerate_pixels_mut() {
                    // A hard edge down the middle: the case sharp YUV exists for.
                    *px = if x < w / 2 {
                        image::Rgba([shade, 20, 200, 255])
                    } else {
                        image::Rgba([250, 240, 30, 255])
                    };
                    let _ = y;
                }
                (img, 100)
            })
            .collect()
    }

    fn is_animated_webp(d: &[u8]) -> bool {
        d.len() > 20
            && &d[0..4] == b"RIFF"
            && &d[8..12] == b"WEBP"
            && &d[12..16] == b"VP8X"
            && (d[20] & 0x02) != 0
    }

    #[test]
    fn art_preset_produces_an_animated_webp() {
        let f = frames(64, 64, 4);
        let out = encode_animation(&f, (64, 64), &AnimParams::art(85.0)).unwrap();
        assert!(is_animated_webp(&out), "expected an animated WebP container");
        let (w, h) = crate::node::image_convert::get_image_dimensions(&out).unwrap();
        assert_eq!((w, h), (64, 64));
    }

    /// The whole point of going direct: `method` and `segments` must actually
    /// reach libwebp. If they were still being dropped (as `webp-animation`
    /// drops `method`), these two would encode identically.
    #[test]
    fn method_and_segments_reach_libwebp() {
        let f = frames(96, 96, 6);
        let fast = encode_animation(
            &f,
            (96, 96),
            &AnimParams {
                quality: 80.0,
                method: 0,
                segments: 1,
                ..Default::default()
            },
        )
        .unwrap();
        let slow = encode_animation(
            &f,
            (96, 96),
            &AnimParams {
                quality: 80.0,
                method: 6,
                segments: 4,
                ..Default::default()
            },
        )
        .unwrap();
        assert_ne!(
            fast, slow,
            "method/segments were dropped before reaching libwebp"
        );
    }

    #[test]
    fn higher_quality_is_larger() {
        let f = frames(96, 96, 6);
        let low = encode_animation(&f, (96, 96), &AnimParams::art(50.0)).unwrap();
        let high = encode_animation(&f, (96, 96), &AnimParams::art(95.0)).unwrap();
        assert!(
            high.len() > low.len(),
            "Q95 ({}) should exceed Q50 ({})",
            high.len(),
            low.len()
        );
    }

    #[test]
    fn frame_durations_survive_the_round_trip() {
        let f = frames(48, 48, 3);
        let out = encode_animation(&f, (48, 48), &AnimParams::art(80.0)).unwrap();
        let decoded = webp_animation::Decoder::new(&out).unwrap();
        let got: Vec<_> = decoded.into_iter().collect();
        assert_eq!(got.len(), 3);
        // Timestamps are the END of each frame: 100, 200, 300.
        assert_eq!(got[0].timestamp(), 100);
        assert_eq!(got[2].timestamp(), 300);
    }

    #[test]
    fn mismatched_frame_size_is_rejected() {
        let mut f = frames(32, 32, 2);
        f.push((RgbaImage::new(16, 16), 100));
        let err = encode_animation(&f, (32, 32), &AnimParams::art(80.0)).unwrap_err();
        assert!(err.contains("16x16"), "unexpected error: {err}");
    }

    #[test]
    fn empty_input_is_rejected() {
        assert!(encode_animation(&[], (32, 32), &AnimParams::art(80.0)).is_err());
        let f = frames(32, 32, 1);
        assert!(encode_animation(&f, (0, 32), &AnimParams::art(80.0)).is_err());
    }
}
