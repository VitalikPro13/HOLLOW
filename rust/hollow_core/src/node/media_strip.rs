//! Location and capture details come off a photo or video before it is sent
//! (C-FILES-03).
//!
//! Containers are edited, never decoded. A video keeps every byte position: a
//! metadata box or element becomes padding of the same length, so chunk
//! offsets, the size committed in the file id and a share's manifest all stay
//! valid. A still image loses its metadata segments and keeps only its
//! orientation, which changes how it displays. Media that does not parse is
//! refused, never sent with whatever it carries; any other file keeps its bytes.

use std::ops::Range;
use std::path::Path;

/// What the sender sees when a photo or video could not be cleaned.
pub(crate) const REFUSED: &str =
    "Could not remove the location and camera details from this file, so it was not sent";

const VIDEO_EXTS: &[&str] = &["mp4", "m4v", "mov", "webm", "mkv", "avi"];
/// Photos, including the HEIF family Hollow shows as a file card.
const IMAGE_EXTS: &[&str] =
    &["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif", "hif", "avif"];

/// True for an extension that goes out as a photo or a video.
pub(crate) fn strips_on_send(ext: &str) -> bool {
    let ext = ext.to_ascii_lowercase();
    VIDEO_EXTS.contains(&ext.as_str()) || IMAGE_EXTS.contains(&ext.as_str())
}

/// The bytes to send for `data` named with `ext`.
pub(crate) fn strip_for_send(ext: &str, mut data: Vec<u8>) -> Result<Vec<u8>, String> {
    let ext = ext.to_ascii_lowercase();
    if VIDEO_EXTS.contains(&ext.as_str()) {
        strip_video(&mut data)?;
        Ok(data)
    } else if IMAGE_EXTS.contains(&ext.as_str()) {
        strip_image(data)
    } else {
        Ok(data)
    }
}

/// Reads a file the user is sending and strips it by its extension. The error
/// is the one the sender reads.
pub(crate) fn read_for_send(path: &Path) -> Result<Vec<u8>, String> {
    let data = super::at_rest::read_all(path).map_err(|e| format!("Failed to read file: {e}"))?;
    let ext = path.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
    strip_for_send(&ext, data).map_err(|e| {
        hollow_log!("[HOLLOW-FILE] metadata strip refused {}: {e}", path.display());
        REFUSED.to_string()
    })
}

/// A video, told apart by its bytes: the name is only the sender's label.
pub(crate) fn strip_video(d: &mut [u8]) -> Result<(), String> {
    if d.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
        strip_matroska(d)
    } else if d.len() >= 12 && &d[0..4] == b"RIFF" && &d[8..12] == b"AVI " {
        strip_avi(d)
    } else {
        strip_isobmff_video(d)
    }
}

/// A still or animated image, told apart by its bytes.
pub(crate) fn strip_image(data: Vec<u8>) -> Result<Vec<u8>, String> {
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        strip_jpeg(&data)
    } else if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        strip_png(&data)
    } else if data.len() >= 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        strip_webp(&data)
    } else if data.starts_with(b"GIF8") {
        Ok(super::image_convert::strip_gif_metadata(&data))
    } else if data.starts_with(b"BM") {
        // A bitmap has nowhere to keep a location.
        Ok(data)
    } else if is_heif(&data) {
        let mut data = data;
        strip_heif(&mut data)?;
        Ok(data)
    } else {
        Err("not an image format this can clean".into())
    }
}

// ── byte helpers ────────────────────────────────────────────────────────────

fn be16(d: &[u8], i: usize) -> Result<u16, String> {
    d.get(i..i + 2).map(|b| u16::from_be_bytes([b[0], b[1]])).ok_or_else(|| "truncated".into())
}

fn be32(d: &[u8], i: usize) -> Result<u32, String> {
    d.get(i..i + 4)
        .map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
        .ok_or_else(|| "truncated".into())
}

fn le32(d: &[u8], i: usize) -> Result<u32, String> {
    d.get(i..i + 4)
        .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .ok_or_else(|| "truncated".into())
}

/// A big-endian unsigned field of 0, 4 or 8 bytes, as `iloc` sizes them.
fn be_sized(d: &[u8], i: usize, n: usize) -> Result<u64, String> {
    let b = d.get(i..i + n).ok_or("truncated")?;
    Ok(b.iter().fold(0u64, |v, x| (v << 8) | *x as u64))
}

fn zero(d: &mut [u8], r: Range<usize>) -> Result<(), String> {
    d.get_mut(r).ok_or("range outside the file")?.fill(0);
    Ok(())
}

// ── ISO base media (mp4, mov, m4v, HEIF) ────────────────────────────────────

#[derive(Clone, Copy)]
struct Bx {
    start: usize,
    /// End of the size, type and large-size fields.
    fields: usize,
    /// Start of the payload, past a `uuid` box's user type.
    body: usize,
    end: usize,
    kind: [u8; 4],
}

fn boxes(d: &[u8], range: Range<usize>, top: bool) -> Result<Vec<Bx>, String> {
    let mut out = Vec::new();
    let mut i = range.start;
    while i < range.end {
        let left = range.end - i;
        if left < 8 {
            // Some writers pad the file's tail with a few zero bytes.
            if top && d[i..range.end].iter().all(|b| *b == 0) {
                break;
            }
            return Err("truncated box header".into());
        }
        let kind: [u8; 4] = [d[i + 4], d[i + 5], d[i + 6], d[i + 7]];
        let (size, fields) = match be32(d, i)? {
            0 => (left as u64, 8),
            1 => (be_sized(d, i + 8, 8)?, 16),
            s => (s as u64, 8),
        };
        let body = fields + if &kind == b"uuid" { 16 } else { 0 };
        if size < body as u64 || size > left as u64 {
            return Err(format!("box {} overruns its parent", String::from_utf8_lossy(&kind)));
        }
        out.push(Bx { start: i, fields: i + fields, body: i + body, end: i + size as usize, kind });
        i += size as usize;
    }
    Ok(out)
}

fn find<'a>(list: &'a [Bx], kind: &[u8; 4]) -> Option<&'a Bx> {
    list.iter().find(|b| &b.kind == kind)
}

/// Turns a box into `free` padding of the same size.
fn to_free(d: &mut [u8], b: &Bx) {
    d[b.start + 4..b.start + 8].copy_from_slice(b"free");
    d[b.fields..b.end].fill(0);
}

/// Zeroes the creation and modification times of an `mvhd`, `tkhd` or `mdhd`.
fn zero_times(d: &mut [u8], b: &Bx) -> Result<(), String> {
    let version = *d.get(b.body).ok_or("empty header box")?;
    let span = if version == 1 { 16 } else { 8 };
    if b.body + 4 + span > b.end {
        return Err("header box too short".into());
    }
    zero(d, b.body + 4..b.body + 4 + span)
}

fn strip_isobmff_video(d: &mut [u8]) -> Result<(), String> {
    let top = boxes(d, 0..d.len(), true)?;
    // A fragmented file keeps its samples in `moof` runs this does not walk.
    let fragmented = find(&top, b"moof").is_some();
    let mut saw_moov = false;
    for b in &top {
        match &b.kind {
            b"moov" => {
                saw_moov = true;
                strip_moov(d, b, fragmented)?;
            }
            b"udta" | b"meta" | b"uuid" => to_free(d, b),
            _ => {}
        }
    }
    if saw_moov { Ok(()) } else { Err("no movie box".into()) }
}

fn strip_moov(d: &mut [u8], moov: &Bx, fragmented: bool) -> Result<(), String> {
    for b in boxes(d, moov.body..moov.end, false)? {
        match &b.kind {
            b"mvhd" => zero_times(d, &b)?,
            b"trak" => strip_trak(d, &b, fragmented)?,
            b"udta" | b"meta" | b"uuid" => to_free(d, &b),
            _ => {}
        }
    }
    Ok(())
}

fn strip_trak(d: &mut [u8], trak: &Bx, fragmented: bool) -> Result<(), String> {
    let kids = boxes(d, trak.body..trak.end, false)?;
    if let Some(mdia) = find(&kids, b"mdia") {
        let mkids = boxes(d, mdia.body..mdia.end, false)?;
        let handler = find(&mkids, b"hdlr").and_then(|h| d.get(h.body + 8..h.body + 12));
        // A timed-metadata track is where action cameras and phones keep a GPS
        // trace: the whole track goes, samples included.
        if handler == Some(b"meta".as_slice()) && !fragmented {
            for r in sample_ranges(d, &mkids)? {
                zero(d, r)?;
            }
            to_free(d, trak);
            return Ok(());
        }
        if let Some(mdhd) = find(&mkids, b"mdhd") {
            zero_times(d, mdhd)?;
        }
        for b in &mkids {
            if matches!(&b.kind, b"udta" | b"meta") {
                to_free(d, b);
            }
        }
    }
    for b in &kids {
        match &b.kind {
            b"tkhd" => zero_times(d, b)?,
            b"udta" | b"meta" | b"uuid" => to_free(d, b),
            _ => {}
        }
    }
    Ok(())
}

/// Where a track's samples sit in the file, from its sample tables.
fn sample_ranges(d: &[u8], mdia_kids: &[Bx]) -> Result<Vec<Range<usize>>, String> {
    let minf = find(mdia_kids, b"minf").ok_or("track without minf")?;
    let minf_kids = boxes(d, minf.body..minf.end, false)?;
    let stbl = find(&minf_kids, b"stbl").ok_or("track without stbl")?;
    let st = boxes(d, stbl.body..stbl.end, false)?;

    let stsz = find(&st, b"stsz").ok_or("track without stsz")?;
    let fixed = be32(d, stsz.body + 4)?;
    let count = be32(d, stsz.body + 8)? as usize;
    if count > d.len() {
        return Err("sample count past the file".into());
    }
    let sizes: Vec<u64> = if fixed != 0 {
        vec![fixed as u64; count]
    } else {
        (0..count).map(|k| be32(d, stsz.body + 12 + 4 * k).map(u64::from)).collect::<Result<_, _>>()?
    };

    let stsc = find(&st, b"stsc").ok_or("track without stsc")?;
    let runs = be32(d, stsc.body + 4)? as usize;
    if runs > d.len() {
        return Err("chunk runs past the file".into());
    }
    let runs: Vec<(u32, u32)> = (0..runs)
        .map(|k| Ok((be32(d, stsc.body + 8 + 12 * k)?, be32(d, stsc.body + 12 + 12 * k)?)))
        .collect::<Result<_, String>>()?;

    let offsets: Vec<u64> = if let Some(co) = find(&st, b"stco") {
        let n = be32(d, co.body + 4)? as usize;
        if n > d.len() {
            return Err("chunk count past the file".into());
        }
        (0..n).map(|k| be32(d, co.body + 8 + 4 * k).map(u64::from)).collect::<Result<_, _>>()?
    } else {
        let co = find(&st, b"co64").ok_or("track without chunk offsets")?;
        let n = be32(d, co.body + 4)? as usize;
        if n > d.len() {
            return Err("chunk count past the file".into());
        }
        (0..n).map(|k| be_sized(d, co.body + 8 + 8 * k, 8)).collect::<Result<_, _>>()?
    };

    let mut out = Vec::new();
    let mut sample = 0usize;
    for (k, &(first, per_chunk)) in runs.iter().enumerate() {
        if first == 0 {
            return Err("chunk numbers start at one".into());
        }
        let last = runs.get(k + 1).map(|n| n.0.saturating_sub(1)).unwrap_or(offsets.len() as u32);
        for chunk in first..=last {
            let mut at = *offsets.get(chunk as usize - 1).ok_or("chunk past the offset table")?;
            for _ in 0..per_chunk {
                let Some(&len) = sizes.get(sample) else { return Ok(out) };
                sample += 1;
                let end = at.checked_add(len).filter(|e| *e <= d.len() as u64).ok_or("sample past the file")?;
                out.push(at as usize..end as usize);
                at = end;
            }
        }
    }
    Ok(out)
}

fn is_heif(d: &[u8]) -> bool {
    d.len() >= 12
        && &d[4..8] == b"ftyp"
        && matches!(
            &d[8..12],
            b"heic" | b"heix" | b"hevc" | b"heim" | b"heis" | b"mif1" | b"msf1" | b"avif" | b"avis"
        )
}

/// Zeroes the Exif and XMP items of a HEIF or AVIF in place. The picture's own
/// rotation lives in item properties, so nothing about how it shows changes.
fn strip_heif(d: &mut [u8]) -> Result<(), String> {
    let top = boxes(d, 0..d.len(), true)?;
    for b in &top {
        if &b.kind == b"uuid" || &b.kind == b"udta" {
            to_free(d, b);
        }
    }
    let meta = *find(&top, b"meta").ok_or("no meta box")?;
    let kids = boxes(d, meta.body + 4..meta.end, false)?;
    let Some(iinf) = find(&kids, b"iinf") else { return Ok(()) };
    let targets = metadata_items(d, iinf)?;
    if targets.is_empty() {
        return Ok(());
    }
    let iloc = find(&kids, b"iloc").ok_or("metadata items without locations")?;
    for r in item_extents(d, iloc, find(&kids, b"idat"), &targets)? {
        zero(d, r)?;
    }
    Ok(())
}

/// Ids of the items holding Exif or XMP.
fn metadata_items(d: &[u8], iinf: &Bx) -> Result<Vec<u32>, String> {
    let version = *d.get(iinf.body).ok_or("empty iinf")?;
    let first = iinf.body + 4 + if version == 0 { 2 } else { 4 };
    let mut out = Vec::new();
    for infe in boxes(d, first..iinf.end, false)? {
        if &infe.kind != b"infe" {
            continue;
        }
        let v = *d.get(infe.body).ok_or("empty infe")?;
        if v < 2 {
            continue;
        }
        let (id, after_id) = if v == 2 {
            (be16(d, infe.body + 4)? as u32, infe.body + 6)
        } else {
            (be32(d, infe.body + 4)?, infe.body + 8)
        };
        let item_type = d.get(after_id + 2..after_id + 6).ok_or("truncated infe")?;
        let rest = &d[(after_id + 6).min(infe.end)..infe.end];
        let is_xmp = item_type == b"mime"
            && rest.windows(7).any(|w| w.eq_ignore_ascii_case(b"rdf+xml"));
        if item_type == b"Exif" || is_xmp {
            out.push(id);
        }
    }
    Ok(out)
}

/// File ranges of the given items' data, from `iloc`.
fn item_extents(d: &[u8], iloc: &Bx, idat: Option<&Bx>, ids: &[u32]) -> Result<Vec<Range<usize>>, String> {
    let version = *d.get(iloc.body).ok_or("empty iloc")?;
    let sizes = *d.get(iloc.body + 4).ok_or("truncated iloc")?;
    let more = *d.get(iloc.body + 5).ok_or("truncated iloc")?;
    let (offset_size, length_size) = ((sizes >> 4) as usize, (sizes & 0x0F) as usize);
    let base_size = (more >> 4) as usize;
    let index_size = if version >= 1 { (more & 0x0F) as usize } else { 0 };
    if [offset_size, length_size, base_size, index_size].iter().any(|s| ![0, 4, 8].contains(s)) {
        return Err("iloc field size".into());
    }
    let mut i = iloc.body + 6;
    let count = if version < 2 {
        i += 2;
        be16(d, i - 2)? as usize
    } else {
        i += 4;
        be32(d, i - 4)? as usize
    };
    let mut out = Vec::new();
    for _ in 0..count {
        let id = if version < 2 {
            i += 2;
            be16(d, i - 2)? as u32
        } else {
            i += 4;
            be32(d, i - 4)?
        };
        let method = if version >= 1 {
            i += 2;
            be16(d, i - 2)? & 0x0F
        } else {
            0
        };
        i += 2; // data_reference_index
        let base = be_sized(d, i, base_size)?;
        i += base_size;
        let extents = be16(d, i)? as usize;
        i += 2;
        for _ in 0..extents {
            i += index_size;
            let off = be_sized(d, i, offset_size)?;
            i += offset_size;
            let len = be_sized(d, i, length_size)?;
            i += length_size;
            if !ids.contains(&id) {
                continue;
            }
            if len == 0 {
                return Err("metadata item runs to the end of the file".into());
            }
            let origin = match method {
                0 => 0u64,
                1 => idat.ok_or("idat item without idat")?.body as u64,
                _ => return Err("metadata item built from other items".into()),
            };
            let start = origin.checked_add(base).and_then(|s| s.checked_add(off)).ok_or("extent overflow")?;
            let end = start.checked_add(len).filter(|e| *e <= d.len() as u64).ok_or("extent past the file")?;
            out.push(start as usize..end as usize);
        }
    }
    Ok(out)
}

// ── Matroska and WebM ───────────────────────────────────────────────────────

const EBML_HEADER: u32 = 0x1A45_DFA3;
const SEGMENT: u32 = 0x1853_8067;
const CLUSTER: u32 = 0x1F43_B675;
const INFO: u32 = 0x1549_A966;
const TAGS: u32 = 0x1254_C367;
const DATE_UTC: u32 = 0x4461;
const TITLE: u32 = 0x7BA9;
/// Elements that sit directly in a Segment, so one of them ends an
/// unknown-size Cluster.
const SEGMENT_LEVEL: &[u32] =
    &[0x114D_9B74, INFO, 0x1654_AE6B, CLUSTER, 0x1C53_BB6B, 0x1941_A469, 0x1043_A770, TAGS];

fn element_id(d: &[u8], i: usize) -> Result<(u32, usize), String> {
    let b = *d.get(i).ok_or("truncated element")?;
    let len = b.leading_zeros() as usize + 1;
    if len > 4 {
        return Err("element id too long".into());
    }
    let raw = d.get(i..i + len).ok_or("truncated element id")?;
    Ok((raw.iter().fold(0u32, |v, x| (v << 8) | *x as u32), len))
}

/// An element size: its value, its width, and whether it is the "unknown" marker.
fn element_size(d: &[u8], i: usize) -> Result<(u64, usize, bool), String> {
    let b = *d.get(i).ok_or("truncated size")?;
    let len = b.leading_zeros() as usize + 1;
    if len > 8 {
        return Err("element size too long".into());
    }
    let raw = d.get(i..i + len).ok_or("truncated size")?;
    let first = if len == 8 { 0 } else { (raw[0] as u64) & ((1u64 << (8 - len)) - 1) };
    let v = raw[1..].iter().fold(first, |v, x| (v << 8) | *x as u64);
    Ok((v, len, v == (1u64 << (7 * len)) - 1))
}

/// Header of the element at `i`: id, payload start, and payload end (None for
/// an unknown size).
fn element(d: &[u8], i: usize, limit: usize) -> Result<(u32, usize, Option<usize>), String> {
    let (id, il) = element_id(d, i)?;
    let (size, sl, unknown) = element_size(d, i + il)?;
    let body = i + il + sl;
    if unknown {
        return Ok((id, body, None));
    }
    let end = (body as u64).checked_add(size).filter(|e| *e <= limit as u64).ok_or("element overruns its parent")?;
    Ok((id, body, Some(end as usize)))
}

/// Overwrites an element with a Void element of the same length.
fn void(d: &mut [u8], start: usize, end: usize) {
    let width = (end - start - 1).min(8);
    let payload = (end - start - 1 - width) as u64;
    d[start] = 0xEC;
    for k in 0..width {
        d[start + 1 + k] = (payload >> (8 * (width - 1 - k))) as u8;
    }
    d[start + 1] |= 1u8 << (8 - width);
    d[start + 1 + width..end].fill(0);
}

fn strip_matroska(d: &mut [u8]) -> Result<(), String> {
    let (id, _, end) = element(d, 0, d.len())?;
    if id != EBML_HEADER {
        return Err("no EBML header".into());
    }
    let mut i = end.ok_or("EBML header of unknown size")?;
    let mut saw_segment = false;
    while i < d.len() {
        let (id, body, end) = element(d, i, d.len())?;
        let end = end.unwrap_or(d.len());
        if id == SEGMENT {
            saw_segment = true;
            strip_segment(d, body, end)?;
        }
        i = end;
    }
    if saw_segment { Ok(()) } else { Err("no segment".into()) }
}

fn strip_segment(d: &mut [u8], from: usize, to: usize) -> Result<(), String> {
    let mut i = from;
    while i < to {
        let (id, body, end) = element(d, i, to)?;
        let end = match end {
            Some(e) => e,
            None if id == CLUSTER => cluster_end(d, body, to)?,
            None => return Err("element of unknown size".into()),
        };
        match id {
            TAGS => void(d, i, end),
            INFO => {
                let mut k = body;
                while k < end {
                    let (child, _, child_end) = element(d, k, end)?;
                    let child_end = child_end.ok_or("info child of unknown size")?;
                    if child == DATE_UTC || child == TITLE {
                        void(d, k, child_end);
                    }
                    k = child_end;
                }
            }
            _ => {}
        }
        i = end;
    }
    Ok(())
}

/// Where a Cluster written without a size ends: at the next Segment-level
/// element, or at the end of the Segment.
fn cluster_end(d: &[u8], from: usize, to: usize) -> Result<usize, String> {
    let mut i = from;
    while i < to {
        let (id, _) = element_id(d, i)?;
        if SEGMENT_LEVEL.contains(&id) {
            return Ok(i);
        }
        let (_, _, end) = element(d, i, to)?;
        i = end.ok_or("cluster child of unknown size")?;
    }
    Ok(to)
}

// ── AVI ─────────────────────────────────────────────────────────────────────

fn strip_avi(d: &mut [u8]) -> Result<(), String> {
    let end = 8usize.checked_add(le32(d, 4)? as usize).filter(|e| *e <= d.len()).ok_or("truncated RIFF")?;
    strip_riff_chunks(d, 12, end)
}

/// Turns the INFO list and the capture date into JUNK chunks of the same size.
fn strip_riff_chunks(d: &mut [u8], from: usize, to: usize) -> Result<(), String> {
    let mut i = from;
    while i + 8 <= to {
        let len = le32(d, i + 4)? as usize;
        let end = (i + 8).checked_add(len).filter(|e| *e <= to).ok_or("chunk overruns its list")?;
        let is_info = &d[i..i + 4] == b"LIST" && d.get(i + 8..i + 12) == Some(b"INFO".as_slice());
        if is_info || &d[i..i + 4] == b"IDIT" {
            d[i..i + 4].copy_from_slice(b"JUNK");
            d[i + 8..end].fill(0);
        } else if &d[i..i + 4] == b"LIST" && d.get(i + 8..i + 12) == Some(b"hdrl".as_slice()) {
            strip_riff_chunks(d, i + 12, end)?;
        }
        i = (end + (len & 1)).min(to);
    }
    Ok(())
}

// ── still images ────────────────────────────────────────────────────────────

/// The Exif orientation (1 to 8) in a TIFF block, if it has one.
fn exif_orientation(tiff: &[u8]) -> Option<u16> {
    let le = match tiff.get(0..2)? {
        b"II" => true,
        b"MM" => false,
        _ => return None,
    };
    let rd16 = |o: usize| {
        tiff.get(o..o + 2).map(|b| if le { u16::from_le_bytes([b[0], b[1]]) } else { u16::from_be_bytes([b[0], b[1]]) })
    };
    let rd32 = |o: usize| {
        tiff.get(o..o + 4).map(|b| {
            let a = [b[0], b[1], b[2], b[3]];
            if le { u32::from_le_bytes(a) } else { u32::from_be_bytes(a) }
        })
    };
    if rd16(2)? != 42 {
        return None;
    }
    let ifd = rd32(4)? as usize;
    let n = rd16(ifd)? as usize;
    (0..n).map(|k| ifd + 2 + 12 * k).find(|&e| rd16(e) == Some(0x0112)).and_then(|e| rd16(e + 8)).filter(|v| (1..=8).contains(v))
}

/// A TIFF block holding nothing but an orientation.
fn orientation_tiff(o: u16) -> Vec<u8> {
    let mut t = b"MM\0\x2A\0\0\0\x08\0\x01\x01\x12\0\x03\0\0\0\x01".to_vec();
    t.extend_from_slice(&o.to_be_bytes());
    t.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
    t
}

/// The Exif payload of an APP1 segment or a WebP EXIF chunk, past any
/// "Exif\0\0" prefix.
fn exif_tiff(payload: &[u8]) -> &[u8] {
    payload.strip_prefix(b"Exif\0\0").unwrap_or(payload)
}

/// Which JPEG marker segments survive.
fn keeps_jpeg_segment(marker: u8, payload: &[u8]) -> bool {
    match marker {
        // JFIF.
        0xE0 => true,
        0xE2 => payload.starts_with(b"ICC_PROFILE\0"),
        // Adobe's colour transform, which CMYK pictures need to decode.
        0xEE => true,
        // Exif, XMP, IPTC, maker blocks, comments.
        0xE1 | 0xE3..=0xED | 0xEF | 0xFE => false,
        _ => true,
    }
}

/// The orientation a JPEG's Exif asks for, when it is not upright.
fn jpeg_orientation(d: &[u8]) -> Option<u16> {
    let mut i = 2;
    while i + 4 <= d.len() && d[i] == 0xFF {
        let marker = d[i + 1];
        match marker {
            0xFF => i += 1,
            0xDA | 0xD9 => return None,
            0x01 | 0xD0..=0xD7 => i += 2,
            _ => {
                let end = i + 2 + be16(d, i + 2).ok()? as usize;
                let payload = d.get(i + 4..end)?;
                if marker == 0xE1 && payload.starts_with(b"Exif\0\0") {
                    return exif_orientation(exif_tiff(payload)).filter(|o| *o != 1);
                }
                i = end;
            }
        }
    }
    None
}

fn strip_jpeg(d: &[u8]) -> Result<Vec<u8>, String> {
    let orientation = jpeg_orientation(d);
    let mut out = Vec::with_capacity(d.len());
    out.extend_from_slice(&[0xFF, 0xD8]);
    let mut placed = false;
    let mut saw_scan = false;
    let mut i = 2;
    while i < d.len() {
        if d[i] != 0xFF {
            return Err("expected a JPEG marker".into());
        }
        let marker = *d.get(i + 1).ok_or("truncated marker")?;
        match marker {
            0xFF => {
                i += 1;
                continue;
            }
            0xD9 => {
                // Whatever follows (a second picture, a gain map) carries its own Exif.
                out.extend_from_slice(&[0xFF, 0xD9]);
                return Ok(out);
            }
            0x01 | 0xD0..=0xD7 => {
                out.extend_from_slice(&d[i..i + 2]);
                i += 2;
                continue;
            }
            _ => {}
        }
        let len = be16(d, i + 2)? as usize;
        let end = i + 2 + len;
        if len < 2 || end > d.len() {
            return Err("JPEG segment overruns the file".into());
        }
        if !placed && marker != 0xE0 {
            placed = true;
            if let Some(o) = orientation {
                let tiff = orientation_tiff(o);
                out.extend_from_slice(&[0xFF, 0xE1]);
                out.extend_from_slice(&((2 + 6 + tiff.len()) as u16).to_be_bytes());
                out.extend_from_slice(b"Exif\0\0");
                out.extend_from_slice(&tiff);
            }
        }
        if keeps_jpeg_segment(marker, &d[i + 4..end]) {
            out.extend_from_slice(&d[i..end]);
        }
        i = end;
        if marker == 0xDA {
            saw_scan = true;
            let j = entropy_end(d, i);
            out.extend_from_slice(&d[i..j]);
            i = j;
        }
    }
    if saw_scan { Ok(out) } else { Err("no image data".into()) }
}

/// End of the entropy-coded data that follows a scan header: the next marker
/// that is not a stuffed byte or a restart.
fn entropy_end(d: &[u8], mut j: usize) -> usize {
    while j + 1 < d.len() {
        if d[j] == 0xFF {
            match d[j + 1] {
                0x00 | 0xD0..=0xD7 => j += 2,
                0xFF => j += 1,
                _ => return j,
            }
        } else {
            j += 1;
        }
    }
    d.len()
}

/// PNG chunks that change how the picture looks or animates. Everything else
/// ancillary (text, Exif, timestamps, provenance) is dropped.
const PNG_KEEP: &[&[u8; 4]] = &[
    b"IHDR", b"PLTE", b"IDAT", b"IEND", b"tRNS", b"gAMA", b"cHRM", b"sRGB", b"iCCP", b"sBIT",
    b"bKGD", b"pHYs", b"cICP", b"mDCV", b"mDCv", b"cLLI", b"cLLi", b"acTL", b"fcTL", b"fdAT",
];

fn strip_png(d: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = d[..8].to_vec();
    let mut i = 8;
    loop {
        let len = be32(d, i)? as usize;
        let end = (i + 12).checked_add(len).filter(|e| *e <= d.len()).ok_or("PNG chunk overruns the file")?;
        let kind = &d[i + 4..i + 8];
        let critical = kind[0].is_ascii_uppercase();
        if critical || PNG_KEEP.iter().any(|k| k.as_slice() == kind) {
            out.extend_from_slice(&d[i..end]);
        }
        i = end;
        if kind == b"IEND" {
            return Ok(out);
        }
    }
}

fn strip_webp(d: &[u8]) -> Result<Vec<u8>, String> {
    let riff_end = 8usize.checked_add(le32(d, 4)? as usize).filter(|e| *e <= d.len()).ok_or("truncated RIFF")?;
    let mut out = d[..12].to_vec();
    let mut vp8x = None;
    let mut orientation = None;
    let mut i = 12;
    while i < riff_end {
        let len = le32(d, i + 4)? as usize;
        let end = (i + 8).checked_add(len).filter(|e| *e <= riff_end).ok_or("WebP chunk overruns the file")?;
        let padded = (end + (len & 1)).min(riff_end);
        match &d[i..i + 4] {
            b"EXIF" => {
                orientation = orientation.or(exif_orientation(exif_tiff(&d[i + 8..end])).filter(|o| *o != 1));
            }
            b"XMP " => {}
            kind => {
                if kind == b"VP8X" {
                    vp8x = Some(out.len());
                }
                out.extend_from_slice(&d[i..padded]);
            }
        }
        i = padded;
    }
    if let Some(at) = vp8x {
        let flags = out.get_mut(at + 8).ok_or("truncated VP8X")?;
        // XMP and EXIF present flags.
        *flags &= !0x0C;
        if let Some(o) = orientation {
            *flags |= 0x08;
            let tiff = orientation_tiff(o);
            out.extend_from_slice(b"EXIF");
            out.extend_from_slice(&(tiff.len() as u32).to_le_bytes());
            out.extend_from_slice(&tiff);
        }
    }
    let size = (out.len() - 8) as u32;
    out[4..8].copy_from_slice(&size.to_le_bytes());
    Ok(out)
}

#[cfg(test)]
pub(crate) mod fixtures {
    //! Media built byte by byte, each carrying a location where its format
    //! keeps one.

    /// The coordinates every fixture hides.
    pub(crate) const LOCATION: &[u8] = b"+37.7749-122.4194";

    pub(crate) fn bx(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = ((8 + body.len()) as u32).to_be_bytes().to_vec();
        v.extend_from_slice(kind);
        v.extend_from_slice(body);
        v
    }

    pub(crate) fn full(kind: &[u8; 4], version: u8, body: &[u8]) -> Vec<u8> {
        bx(kind, &[&[version, 0, 0, 0][..], body].concat())
    }

    const STAMP: [u8; 4] = [0xE1, 0x23, 0x45, 0x67];

    fn track(id: u8, handler: &[u8; 4], sample_offset: u32, sample_len: u32) -> Vec<u8> {
        let tkhd = full(b"tkhd", 0, &[&STAMP[..], &STAMP, &[0, 0, 0, id], &[0; 68]].concat());
        let mdhd = full(b"mdhd", 0, &[&STAMP[..], &STAMP, &[0, 0, 0x03, 0xE8, 0, 0, 0x03, 0xE8, 0x55, 0xC4, 0, 0]].concat());
        let hdlr = full(b"hdlr", 0, &[&[0u8; 4][..], handler, &[0; 12], b"Handler\0"].concat());
        let stsd = full(b"stsd", 0, &[0, 0, 0, 0]);
        let stsc = full(b"stsc", 0, &[0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]);
        let stsz = full(b"stsz", 0, &[&[0u8; 4][..], &[0, 0, 0, 1], &sample_len.to_be_bytes()].concat());
        let stco = full(b"stco", 0, &[&[0, 0, 0, 1][..], &sample_offset.to_be_bytes()].concat());
        let stbl = bx(b"stbl", &[stsd, stsc, stsz, stco].concat());
        let minf = bx(b"minf", &stbl);
        let mdia = bx(b"mdia", &[mdhd, hdlr, minf].concat());
        bx(b"trak", &[tkhd, mdia].concat())
    }

    /// An mp4 the way a phone writes one: a video track, a timed GPS track,
    /// Android's `©xyz` in `udta` and Apple's ISO 6709 key in `meta`.
    pub(crate) fn mp4_with_location() -> Vec<u8> {
        let ftyp = bx(b"ftyp", b"isom\0\0\x02\0isommp41");
        let video = b"VIDEO-SAMPLE-BYTES".to_vec();
        let gps = [b"GPS ".as_slice(), LOCATION].concat();
        let moov = |video_at: u32, gps_at: u32| {
            let mvhd = full(b"mvhd", 0, &[&STAMP[..], &STAMP, &[0, 0, 0x03, 0xE8, 0, 0, 0x03, 0xE8], &[0; 80]].concat());
            let xyz = bx(b"\xA9xyz", &[&[0, LOCATION.len() as u8 + 1, 0x15, 0xC7][..], LOCATION, b"/"].concat());
            let udta = bx(b"udta", &xyz);
            let keys = full(b"keys", 0, &[&[0, 0, 0, 1][..], &bx(b"mdta", b"com.apple.quicktime.location.ISO6709")].concat());
            let ilst = bx(b"ilst", &bx(&[0, 0, 0, 1], &bx(b"data", &[&[0, 0, 0, 1, 0, 0, 0, 0][..], LOCATION].concat())));
            let meta = full(b"meta", 0, &[full(b"hdlr", 0, &[&[0u8; 4][..], b"mdta", &[0; 13]].concat()), keys, ilst].concat());
            bx(
                b"moov",
                &[mvhd, track(1, b"vide", video_at, video.len() as u32), track(2, b"meta", gps_at, gps.len() as u32), udta, meta]
                    .concat(),
            )
        };
        let head = ftyp.len() + moov(0, 0).len() + 8;
        let mdat = bx(b"mdat", &[video.as_slice(), &gps].concat());
        [ftyp, moov(head as u32, (head + video.len()) as u32), mdat].concat()
    }

    fn ebml(id: &[u8], body: &[u8]) -> Vec<u8> {
        assert!(body.len() < 0x3FFF);
        [id, &[0x40 | (body.len() >> 8) as u8, body.len() as u8], body].concat()
    }

    /// A WebM written the way a recorder streams one: Segment and Cluster of
    /// unknown size, then Tags carrying a location.
    pub(crate) fn webm_with_location() -> Vec<u8> {
        let header = ebml(&[0x1A, 0x45, 0xDF, 0xA3], &ebml(&[0x42, 0x82], b"webm"));
        let info = ebml(&[0x15, 0x49, 0xA9, 0x66], &[ebml(&[0x44, 0x61], &[1, 2, 3, 4, 5, 6, 7, 8]), ebml(&[0x7B, 0xA9], b"Holiday")].concat());
        let tracks = ebml(&[0x16, 0x54, 0xAE, 0x6B], &ebml(&[0xAE], &ebml(&[0xD7], &[1])));
        let cluster = [
            &[0x1F, 0x43, 0xB6, 0x75, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF][..],
            &ebml(&[0xE7], &[0]),
            &ebml(&[0xA3], b"\x81\0\0\x80FRAME"),
        ]
        .concat();
        let tag = ebml(&[0x73, 0x73], &ebml(&[0x67, 0xC8], &[ebml(&[0x45, 0xA3], b"LOCATION"), ebml(&[0x44, 0x87], LOCATION)].concat()));
        let tags = ebml(&[0x12, 0x54, 0xC3, 0x67], &tag);
        let segment = [&[0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF][..], &info, &tracks, &cluster, &tags].concat();
        [header, segment].concat()
    }

    fn riff(id: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = id.to_vec();
        v.extend_from_slice(&(body.len() as u32).to_le_bytes());
        v.extend_from_slice(body);
        if body.len() % 2 == 1 {
            v.push(0);
        }
        v
    }

    pub(crate) fn avi_with_location() -> Vec<u8> {
        let hdrl = riff(b"LIST", &[b"hdrl".as_slice(), &riff(b"avih", &[0; 56]), &riff(b"IDIT", b"Mon Oct 04 12:00:00 2026\n")].concat());
        let info = riff(b"LIST", &[b"INFO".as_slice(), &riff(b"ICMT", LOCATION)].concat());
        let movi = riff(b"LIST", &[b"movi".as_slice(), &riff(b"00dc", b"FRAME")].concat());
        riff(b"RIFF", &[b"AVI ".as_slice(), &hdrl, &info, &movi].concat())
    }

    /// A TIFF block with an orientation and a GPS IFD holding a latitude.
    pub(crate) fn exif_with_gps(orientation: u16) -> Vec<u8> {
        let mut t = b"II\x2A\0\x08\0\0\0".to_vec();
        // IFD0: orientation and the GPS pointer.
        t.extend_from_slice(&2u16.to_le_bytes());
        t.extend_from_slice(&[0x12, 0x01, 3, 0, 1, 0, 0, 0]);
        t.extend_from_slice(&orientation.to_le_bytes());
        t.extend_from_slice(&[0, 0]);
        t.extend_from_slice(&[0x25, 0x88, 4, 0, 1, 0, 0, 0, 38, 0, 0, 0]);
        t.extend_from_slice(&[0, 0, 0, 0]);
        // GPS IFD at 38: GPSLatitudeRef "N" and the coordinates as ASCII.
        t.extend_from_slice(&2u16.to_le_bytes());
        t.extend_from_slice(&[0x01, 0x00, 2, 0, 2, 0, 0, 0, b'N', 0, 0, 0]);
        t.extend_from_slice(&[0x1B, 0x00, 2, 0, LOCATION.len() as u8, 0, 0, 0, 68, 0, 0, 0]);
        t.extend_from_slice(&[0, 0, 0, 0]);
        t.extend_from_slice(LOCATION);
        t
    }

    pub(crate) fn jpeg_with_gps(orientation: u16) -> Vec<u8> {
        let img = image::RgbImage::from_pixel(16, 8, image::Rgb([200, 40, 40]));
        let mut plain = Vec::new();
        image::codecs::jpeg::JpegEncoder::new(&mut plain).encode_image(&img).expect("encode jpeg");
        let exif = [b"Exif\0\0".as_slice(), &exif_with_gps(orientation)].concat();
        let xmp = [b"http://ns.adobe.com/xap/1.0/\0<x:xmpmeta><exif:GPSLatitude>".as_slice(), LOCATION, b"</exif:GPSLatitude></x:xmpmeta>"].concat();
        let comment = [b"shot at ".as_slice(), LOCATION].concat();
        let seg = |m: u8, p: &[u8]| [&[0xFF, m][..], &((p.len() + 2) as u16).to_be_bytes(), p].concat();
        let trailing_picture = [&[0xFF, 0xD8][..], &seg(0xE1, &exif), &[0xFF, 0xD9]].concat();
        [&plain[..2], &seg(0xE1, &exif), &seg(0xE1, &xmp), &seg(0xFE, &comment), &plain[2..], &trailing_picture].concat()
    }

    pub(crate) fn png_with_gps() -> Vec<u8> {
        let img = image::RgbaImage::from_pixel(4, 4, image::Rgba([1, 2, 3, 255]));
        let mut plain = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut plain), image::ImageFormat::Png).expect("encode png");
        let chunk = |kind: &[u8; 4], body: &[u8]| {
            let mut v = (body.len() as u32).to_be_bytes().to_vec();
            v.extend_from_slice(kind);
            v.extend_from_slice(body);
            v.extend_from_slice(&[0, 0, 0, 0]);
            v
        };
        // After IHDR (8 + 25 bytes).
        let at = 33;
        [&plain[..at], &chunk(b"eXIf", &exif_with_gps(6)), &chunk(b"tEXt", &[b"Location\0".as_slice(), LOCATION].concat()), &plain[at..]].concat()
    }

    pub(crate) fn webp_with_gps(orientation: u16) -> Vec<u8> {
        let img = image::RgbaImage::from_pixel(4, 4, image::Rgba([9, 8, 7, 255]));
        let mut simple = Vec::new();
        img.write_to(&mut std::io::Cursor::new(&mut simple), image::ImageFormat::WebP).expect("encode webp");
        let chunk = |kind: &[u8; 4], body: &[u8]| {
            let mut v = kind.to_vec();
            v.extend_from_slice(&(body.len() as u32).to_le_bytes());
            v.extend_from_slice(body);
            if body.len() % 2 == 1 {
                v.push(0);
            }
            v
        };
        // VP8X: EXIF and XMP flags, 4x4 canvas (stored minus one, 24-bit).
        let vp8x = chunk(b"VP8X", &[0x0C, 0, 0, 0, 3, 0, 0, 3, 0, 0]);
        let body = [
            b"WEBP".as_slice(),
            &vp8x,
            &simple[12..],
            &chunk(b"EXIF", &exif_with_gps(orientation)),
            &chunk(b"XMP ", &[b"<x:xmpmeta>".as_slice(), LOCATION, b"</x:xmpmeta>"].concat()),
        ]
        .concat();
        let mut out = b"RIFF".to_vec();
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out.extend_from_slice(&body);
        out
    }

    /// A HEIC skeleton: the picture item and an Exif item whose bytes sit in
    /// `mdat`, located by a version 1 `iloc`.
    pub(crate) fn heic_with_gps() -> Vec<u8> {
        let ftyp = bx(b"ftyp", b"heic\0\0\0\0mif1heic");
        let exif = [&[0u8, 0, 0, 6][..], b"Exif\0\0", &exif_with_gps(6)].concat();
        let picture = b"HEVC-PICTURE".to_vec();
        let meta = |pic_at: u32, exif_at: u32| {
            let hdlr = full(b"hdlr", 0, &[&[0u8; 4][..], b"pict", &[0; 13]].concat());
            let pitm = full(b"pitm", 0, &[0, 1]);
            let infe = |id: u8, t: &[u8; 4]| full(b"infe", 2, &[&[0, id, 0, 0][..], t, b"\0"].concat());
            let iinf = full(b"iinf", 0, &[&[0, 2][..], &infe(1, b"hvc1"), &infe(2, b"Exif")].concat());
            let item = |id: u8, at: u32, len: usize| {
                [&[0, id, 0, 0, 0, 0][..], &[0, 1], &at.to_be_bytes(), &(len as u32).to_be_bytes()].concat()
            };
            let iloc = full(b"iloc", 1, &[&[0x44, 0x00, 0, 2][..], &item(1, pic_at, picture.len()), &item(2, exif_at, exif.len())].concat());
            full(b"meta", 0, &[hdlr, pitm, iinf, iloc].concat())
        };
        let head = ftyp.len() + meta(0, 0).len() + 8;
        let mdat = bx(b"mdat", &[picture.as_slice(), &exif].concat());
        [ftyp, meta(head as u32, (head + picture.len()) as u32), mdat].concat()
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::*;
    use super::*;

    fn holds(d: &[u8], needle: &[u8]) -> bool {
        d.windows(needle.len()).any(|w| w == needle)
    }

    #[test]
    fn an_mp4_loses_its_location_and_keeps_every_offset() {
        let before = mp4_with_location();
        assert!(holds(&before, LOCATION));
        let after = strip_for_send("mp4", before.clone()).expect("a well formed mp4 strips");

        assert_eq!(after.len(), before.len(), "every byte keeps its position");
        assert!(!holds(&after, LOCATION), "no copy of the location survives, the GPS track's samples included");
        assert!(holds(&after, b"VIDEO-SAMPLE-BYTES"), "the picture is untouched");
        assert!(!holds(&after, &[0xE1, 0x23, 0x45, 0x67]), "creation and modification times are zeroed");

        // Still a valid file: the walk that refuses broken files accepts it,
        // and the video track's tables still point at the picture.
        let top = boxes(&after, 0..after.len(), true).expect("valid boxes");
        let moov = find(&top, b"moov").expect("moov");
        let kids = boxes(&after, moov.body..moov.end, false).expect("moov children");
        let kinds: Vec<&[u8; 4]> = kids.iter().map(|b| &b.kind).collect();
        assert_eq!(kinds, [b"mvhd", b"trak", b"free", b"free", b"free"], "GPS track, udta and meta became padding");
        let trak = kids[1];
        let mdia = *find(&boxes(&after, trak.body..trak.end, false).unwrap(), b"mdia").unwrap();
        let ranges = sample_ranges(&after, &boxes(&after, mdia.body..mdia.end, false).unwrap()).unwrap();
        assert_eq!(&after[ranges[0].clone()], b"VIDEO-SAMPLE-BYTES");

        assert_eq!(strip_for_send("mp4", after.clone()).unwrap(), after, "stripping twice changes nothing");
    }

    #[test]
    fn a_webm_and_an_avi_lose_their_tags_and_keep_their_length() {
        let webm = webm_with_location();
        let out = strip_for_send("webm", webm.clone()).expect("webm strips");
        assert_eq!(out.len(), webm.len());
        assert!(!holds(&out, LOCATION) && !holds(&out, b"Holiday") && !holds(&out, &[1, 2, 3, 4, 5, 6, 7, 8]));
        assert!(holds(&out, b"FRAME"), "the cluster written without a size is walked, not voided");
        strip_matroska(&mut out.clone()).expect("the voided file still walks");

        let avi = avi_with_location();
        let out = strip_for_send("avi", avi.clone()).expect("avi strips");
        assert_eq!(out.len(), avi.len());
        assert!(!holds(&out, LOCATION) && !holds(&out, b"2026"));
        assert!(holds(&out, b"FRAME"));
    }

    #[test]
    fn a_jpeg_loses_its_gps_exif_and_keeps_its_orientation() {
        let before = jpeg_with_gps(6);
        assert!(holds(&before, LOCATION));
        let after = strip_for_send("jpg", before.clone()).expect("jpeg strips");

        assert!(!holds(&after, LOCATION), "Exif GPS, XMP, the comment and the trailing picture are gone");
        assert!(after.ends_with(&[0xFF, 0xD9]), "nothing follows the picture's end");
        let app1 = after.windows(8).position(|w| w == b"Exif\0\0MM").expect("orientation Exif kept") + 6;
        assert_eq!(exif_orientation(&after[app1..]), Some(6));
        let a = image::load_from_memory(&after).expect("still decodes").to_rgb8();
        let b = image::load_from_memory(&before).unwrap().to_rgb8();
        assert_eq!(a, b, "identical pixels");

        let upright = strip_for_send("jpg", jpeg_with_gps(1)).unwrap();
        assert!(!holds(&upright, b"Exif"), "an upright picture needs no Exif at all");
    }

    #[test]
    fn png_webp_and_heic_lose_their_gps() {
        let png = strip_for_send("png", png_with_gps()).expect("png strips");
        assert!(!holds(&png, LOCATION) && !holds(&png, b"eXIf"));
        image::load_from_memory(&png).expect("png still decodes");

        let webp = strip_for_send("webp", webp_with_gps(8)).expect("webp strips");
        assert!(!holds(&webp, LOCATION) && !holds(&webp, b"XMP "));
        assert_eq!(u32::from_le_bytes(webp[4..8].try_into().unwrap()) as usize, webp.len() - 8);
        let exif = webp.windows(4).position(|w| w == b"EXIF").expect("orientation kept") + 8;
        assert_eq!(exif_orientation(&webp[exif..]), Some(8));
        assert_eq!(webp[20] & 0x0C, 0x08, "VP8X now claims EXIF only");
        image::load_from_memory(&webp).expect("webp still decodes");

        let heic = heic_with_gps();
        let out = strip_for_send("heic", heic.clone()).expect("heic strips");
        assert_eq!(out.len(), heic.len());
        assert!(!holds(&out, LOCATION));
        assert!(holds(&out, b"HEVC-PICTURE"), "only the Exif item is zeroed");
    }

    /// Each read of a file the user is sending goes through the strip: the two
    /// FFI reads (vault upload, large-file share) have no harness of their own.
    #[test]
    fn every_send_read_goes_through_the_strip() {
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let body = |file: &str, from: &str| {
            let s = std::fs::read_to_string(src.join(file)).expect("read source").replace("\r\n", "\n");
            let start = s.find(from).unwrap_or_else(|| panic!("missing {from}"));
            let end = s[start..].find("\n}\n").expect("function end");
            s[start..start + end].to_string()
        };
        assert!(body("api/crdt.rs", "pub fn vault_upload_file(").contains("media_strip::read_for_send("), "the vault keeps the original photo");
        assert!(body("api/share.rs", "pub fn share_create_for_send(").contains("cleaned_send_source("), "a large send shares the user's own file");
        assert!(body("node/share_handler.rs", "pub(crate) fn cleaned_send_source(").contains("media_strip::read_for_send("));
        assert!(body("node/file_handler.rs", "pub(crate) async fn handle_send_file(").contains("media_strip::read_for_send("));
    }

    #[test]
    fn media_that_does_not_parse_is_refused_and_files_pass_untouched() {
        assert!(strip_for_send("mp4", b"not really h264".to_vec()).is_err());
        let mut cut = mp4_with_location();
        cut.truncate(cut.len() - 30);
        assert!(strip_for_send("mov", cut).is_err(), "a box past the end is refused");
        let no_movie = [bx(b"ftyp", b"isom\0\0\0\0"), bx(b"mdat", LOCATION)].concat();
        assert!(strip_for_send("mp4", no_movie).is_err(), "boxes without a movie are not a video");
        assert!(strip_for_send("jpg", b"\xFF\xD8\xFF\xE1\xFF\xFF".to_vec()).is_err());
        assert!(strip_for_send("heic", b"plain text".to_vec()).is_err());

        let doc = b"%PDF-1.7 with a location +37.7749-122.4194".to_vec();
        assert_eq!(strip_for_send("pdf", doc.clone()).unwrap(), doc, "a file keeps its bytes");
        assert!(strips_on_send("MOV") && strips_on_send("heic") && !strips_on_send("pdf") && !strips_on_send("ogg"));
    }
}
