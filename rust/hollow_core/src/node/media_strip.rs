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
        hollow_log!("[HOLLOW-FILE] metadata strip refused {}: {e}", crate::log::redact_file(path));
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
        super::image_convert::strip_gif_metadata(&data)
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

/// The boxes laid end to end in a range, 13 bytes each: a box takes at least
/// 8 bytes of the file, and a whole `Bx` apiece made the list five times the
/// file (HOL-SEC-303). A box ends where the next one starts.
struct Boxes {
    starts: Vec<u64>,
    kinds: Vec<[u8; 4]>,
    /// Header length: 8, or 16 with a 64-bit size.
    heads: Vec<u8>,
    end: usize,
}

impl Boxes {
    fn get(&self, k: usize) -> Option<Bx> {
        let start = *self.starts.get(k)? as usize;
        let end = self.starts.get(k + 1).map_or(self.end, |s| *s as usize);
        let fields = start + *self.heads.get(k)? as usize;
        let kind = *self.kinds.get(k)?;
        let body = fields + if &kind == b"uuid" { 16 } else { 0 };
        Some(Bx { start, fields, body, end, kind })
    }

    fn iter(&self) -> impl Iterator<Item = Bx> + '_ {
        (0..self.starts.len()).filter_map(|k| self.get(k))
    }
}

/// Walks the box headers in `range`, handing `each` every box's start, header
/// length and kind. Returns how many boxes there were and where the last ends.
fn walk_boxes(d: &[u8], range: Range<usize>, top: bool, mut each: impl FnMut(usize, u8, [u8; 4])) -> Result<(usize, usize), String> {
    let mut n = 0;
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
        each(i, fields as u8, kind);
        n += 1;
        i += size as usize;
    }
    Ok((n, i))
}

fn boxes(d: &[u8], range: Range<usize>, top: bool) -> Result<Boxes, String> {
    // Counted first, so the lists take exactly the room they hold.
    let (n, _) = walk_boxes(d, range.clone(), top, |_, _, _| {})?;
    let mut list = Boxes {
        starts: Vec::with_capacity(n),
        kinds: Vec::with_capacity(n),
        heads: Vec::with_capacity(n),
        end: range.start,
    };
    let (_, end) = walk_boxes(d, range, top, |start, head, kind| {
        list.starts.push(start as u64);
        list.heads.push(head);
        list.kinds.push(kind);
    })?;
    list.end = end;
    Ok(list)
}

fn find(list: &Boxes, kind: &[u8; 4]) -> Option<Bx> {
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

/// How many bytes one file's strip may still zero. Honest metadata samples
/// and extents never overlap, so they cover the file at most once; ones laid
/// over each other could ask for terabytes (HOL-SEC-269). Twice the file is
/// the slack an odd but honest file gets.
struct Budget(u64);

impl Budget {
    fn for_file(len: usize) -> Self {
        Budget(2 * len as u64 + 4096)
    }

    fn charge(&mut self, r: &Range<usize>) -> Result<(), String> {
        self.0 = self.0.checked_sub(r.len() as u64).ok_or("the metadata to remove overlaps itself")?;
        Ok(())
    }
}

fn strip_isobmff_video(d: &mut [u8]) -> Result<(), String> {
    let top = boxes(d, 0..d.len(), true)?;
    // A fragmented file keeps its samples in `moof` runs, which
    // `strip_fragments` walks for the timed-metadata tracks.
    let fragmented = find(&top, b"moof").is_some();
    let meta = fragment_tracks(d, &top)?;
    let mut budget = Budget::for_file(d.len());
    let mut saw_moov = false;
    for b in top.iter() {
        match &b.kind {
            b"moov" => {
                saw_moov = true;
                strip_moov(d, &b, fragmented, &mut budget)?;
            }
            b"udta" | b"meta" | b"uuid" | b"gps " => to_free(d, &b),
            _ => {}
        }
    }
    strip_fragments(d, &top, &meta, &mut budget)?;
    if saw_moov { Ok(()) } else { Err("no movie box".into()) }
}

/// The tracks a fragmented movie's `moof` runs name, with their `trex` default
/// sample sizes, and which of them carry timed metadata.
struct FragmentTracks {
    /// (track id, default sample size, timed metadata)
    tracks: Vec<(u32, Option<u32>, bool)>,
}

impl FragmentTracks {
    fn get(&self, id: u32) -> Option<(Option<u32>, bool)> {
        self.tracks.iter().find(|t| t.0 == id).map(|t| (t.1, t.2))
    }

    fn any_meta(&self) -> bool {
        self.tracks.iter().any(|t| t.2)
    }
}

/// Reads, before anything is zeroed, which tracks of a fragmented movie are
/// timed metadata: their samples sit in `moof` runs, which 0.14 sent as they
/// were, GPS trace included (HOL-SEC-305). A movie without fragments needs none.
fn fragment_tracks(d: &[u8], top: &Boxes) -> Result<FragmentTracks, String> {
    let mut out = FragmentTracks { tracks: Vec::new() };
    let (Some(moov), true) = (find(top, b"moov"), find(top, b"moof").is_some()) else { return Ok(out) };
    let kids = boxes(d, moov.body..moov.end, false)?;
    for trak in kids.iter().filter(|b| &b.kind == b"trak") {
        let tk = boxes(d, trak.body..trak.end, false)?;
        let Some(tkhd) = find(&tk, b"tkhd") else { continue };
        let version = *d.get(tkhd.body).ok_or("empty tkhd")?;
        let id = be32(d, tkhd.body + if version == 1 { 20 } else { 12 })?;
        let meta = match find(&tk, b"mdia") {
            Some(mdia) => {
                let mk = boxes(d, mdia.body..mdia.end, false)?;
                gps_track(find(&mk, b"hdlr").and_then(|h| d.get(h.body + 8..h.body + 12)))
            }
            None => false,
        };
        out.tracks.push((id, None, meta));
    }
    if let Some(mvex) = find(&kids, b"mvex") {
        for trex in boxes(d, mvex.body..mvex.end, false)?.iter().filter(|b| &b.kind == b"trex") {
            if trex.body + 24 > trex.end {
                return Err("trex too short".into());
            }
            let id = be32(d, trex.body + 4)?;
            let size = be32(d, trex.body + 16)?;
            for t in out.tracks.iter_mut().filter(|t| t.0 == id) {
                t.1 = Some(size);
            }
        }
    }
    Ok(out)
}

/// Zeroes the data every `moof` gives a timed-metadata track (HOL-SEC-305).
/// Each `moof` is read from a copy, so zeroing cannot change what a later
/// fragment of it says.
fn strip_fragments(d: &mut [u8], top: &Boxes, tracks: &FragmentTracks, budget: &mut Budget) -> Result<(), String> {
    if !tracks.any_meta() {
        return Ok(());
    }
    for moof in top.iter().filter(|b| &b.kind == b"moof") {
        let m = d.get(moof.start..moof.end).ok_or("moof past the file")?.to_vec();
        for r in fragment_runs(&m, moof.start, moof.body - moof.start, tracks)? {
            budget.charge(&r)?;
            zero(d, r)?;
        }
    }
    Ok(())
}

/// The file range of every run a timed-metadata track has in one `moof`,
/// given as `m` (its bytes, starting at `at` in the file, its children from
/// `head`). A run's samples lie end to end, so a run is one range.
fn fragment_runs(m: &[u8], at: usize, head: usize, tracks: &FragmentTracks) -> Result<Vec<Range<usize>>, String> {
    let mut out = Vec::new();
    // Where the previous track fragment's data ended, if it can be known.
    let mut prev_end = Some(at as u64);
    for traf in boxes(m, head..m.len(), false)?.iter().filter(|b| &b.kind == b"traf") {
        let kids = boxes(m, traf.body..traf.end, false)?;
        let tfhd = find(&kids, b"tfhd").ok_or("track fragment without tfhd")?;
        if tfhd.body + 8 > tfhd.end {
            return Err("tfhd too short".into());
        }
        let flags = be32(m, tfhd.body)? & 0x00FF_FFFF;
        let id = be32(m, tfhd.body + 4)?;
        let mut p = tfhd.body + 8;
        let mut field = |n: usize| -> Result<u64, String> {
            if p + n > tfhd.end {
                return Err("tfhd too short".into());
            }
            p += n;
            be_sized(m, p - n, n)
        };
        let base_offset = if flags & 0x01 != 0 { Some(field(8)?) } else { None };
        if flags & 0x02 != 0 {
            field(4)?;
        }
        if flags & 0x08 != 0 {
            field(4)?;
        }
        let tfhd_size = if flags & 0x10 != 0 { Some(field(4)?) } else { None };
        let (trex_size, meta) = tracks.get(id).unwrap_or((None, false));
        let base = match base_offset {
            Some(b) => Some(b),
            None if flags & 0x02_0000 != 0 => Some(at as u64),
            None => prev_end,
        };
        let mut next = base;
        for trun in kids.iter().filter(|b| &b.kind == b"trun") {
            if trun.body + 8 > trun.end {
                return Err("trun too short".into());
            }
            let tflags = be32(m, trun.body)? & 0x00FF_FFFF;
            let count = be32(m, trun.body + 4)? as usize;
            let mut q = trun.body + 8;
            let offset = if tflags & 0x001 != 0 { Some(i64::from(be32(m, q)? as i32)) } else { None };
            q += 4 * (tflags & 0x001) as usize + if tflags & 0x004 != 0 { 4 } else { 0 };
            let record = 4 * (tflags & 0xF00).count_ones() as usize;
            if q > trun.end || (record > 0 && count > (trun.end - q) / record) {
                return Err("trun longer than its box".into());
            }
            let start = match offset {
                Some(off) => base.and_then(|b| b.checked_add_signed(off)),
                None => next,
            };
            let total = if tflags & 0x200 != 0 {
                // The size follows the duration when a record has both.
                let size_at = q + if tflags & 0x100 != 0 { 4 } else { 0 };
                let mut sum = 0u64;
                for k in 0..count {
                    sum += u64::from(be32(m, size_at + k * record)?);
                }
                Some(sum)
            } else {
                tfhd_size.or(trex_size.map(u64::from)).map(|s| (count as u64).saturating_mul(s))
            };
            next = start.zip(total).and_then(|(s, t)| s.checked_add(t));
            if meta {
                let (s, e) = start.zip(next).ok_or("timed metadata run whose place is unknown")?;
                out.push(s as usize..e as usize);
            }
        }
        prev_end = next;
    }
    Ok(out)
}

fn strip_moov(d: &mut [u8], moov: &Bx, fragmented: bool, budget: &mut Budget) -> Result<(), String> {
    for b in boxes(d, moov.body..moov.end, false)?.iter() {
        match &b.kind {
            b"mvhd" => zero_times(d, &b)?,
            b"trak" => strip_trak(d, &b, fragmented, budget)?,
            // A dashcam's `gps ` box holds its GPS log or an index to it
            // (HOL-SEC-306).
            b"udta" | b"meta" | b"uuid" | b"gps " => to_free(d, &b),
            _ => {}
        }
    }
    Ok(())
}

fn strip_trak(d: &mut [u8], trak: &Bx, fragmented: bool, budget: &mut Budget) -> Result<(), String> {
    let kids = boxes(d, trak.body..trak.end, false)?;
    if let Some(mdia) = find(&kids, b"mdia") {
        let mkids = boxes(d, mdia.body..mdia.end, false)?;
        let handler = find(&mkids, b"hdlr").and_then(|h| d.get(h.body + 8..h.body + 12));
        // A timed-metadata track is where action cameras and phones keep a GPS
        // trace: the whole track goes, samples included.
        if gps_track(handler) && !fragmented {
            sample_tables(d, &mkids)?.walk(d.len(), |r| {
                budget.charge(&r)?;
                zero(d, r)
            })?;
            to_free(d, trak);
            return Ok(());
        }
        if let Some(mdhd) = find(&mkids, b"mdhd") {
            zero_times(d, &mdhd)?;
        }
        for b in mkids.iter() {
            if matches!(&b.kind, b"udta" | b"meta") {
                to_free(d, &b);
            }
        }
    }
    for b in kids.iter() {
        match &b.kind {
            b"tkhd" => zero_times(d, &b)?,
            b"udta" | b"meta" | b"uuid" => to_free(d, &b),
            _ => {}
        }
    }
    Ok(())
}

/// Whether a track's handler marks timed metadata, where cameras keep a GPS
/// trace: `meta`, or Google's camera motion `camm` (HOL-SEC-306).
fn gps_track(handler: Option<&[u8]>) -> bool {
    matches!(handler, Some(b"meta") | Some(b"camm"))
}

/// A track's chunk offsets, as wide as the file wrote them.
enum Offsets {
    Short(Vec<u32>),
    Long(Vec<u64>),
}

impl Offsets {
    fn len(&self) -> usize {
        match self {
            Offsets::Short(v) => v.len(),
            Offsets::Long(v) => v.len(),
        }
    }

    fn get(&self, k: usize) -> Option<u64> {
        match self {
            Offsets::Short(v) => v.get(k).map(|o| u64::from(*o)),
            Offsets::Long(v) => v.get(k).copied(),
        }
    }
}

/// A track's sample tables, read out of the file before its samples are
/// zeroed. Each entry is held at the width the file gave it.
struct SampleTables {
    /// Each sample's size; empty when `fixed` gives every one of `count`.
    sizes: Vec<u32>,
    fixed: u32,
    count: usize,
    runs: Vec<(u32, u32)>,
    offsets: Offsets,
}

/// Checks that `n` entries of `width` bytes from `from` lie inside the table's
/// own box. A count reaching further read other boxes' bytes again for every
/// track, and held them as entries (HOL-SEC-302).
fn table_fits(b: &Bx, from: usize, width: usize, n: usize) -> Result<(), String> {
    if n > b.end.saturating_sub(from) / width {
        return Err(format!("{} table runs past its box", String::from_utf8_lossy(&b.kind)));
    }
    Ok(())
}

/// Where a track's samples sit in the file, from its sample tables.
fn sample_tables(d: &[u8], mdia_kids: &Boxes) -> Result<SampleTables, String> {
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
    // A fixed size names up to one sample per byte of the file, so it is
    // never spread into a list (HOL-SEC-302).
    let mut sizes = Vec::new();
    if fixed == 0 {
        table_fits(&stsz, stsz.body + 12, 4, count)?;
        sizes.reserve_exact(count);
        for k in 0..count {
            sizes.push(be32(d, stsz.body + 12 + 4 * k)?);
        }
    }

    let stsc = find(&st, b"stsc").ok_or("track without stsc")?;
    let n = be32(d, stsc.body + 4)? as usize;
    if n > d.len() {
        return Err("chunk runs past the file".into());
    }
    table_fits(&stsc, stsc.body + 8, 12, n)?;
    let mut runs = Vec::with_capacity(n);
    for k in 0..n {
        runs.push((be32(d, stsc.body + 8 + 12 * k)?, be32(d, stsc.body + 12 + 12 * k)?));
    }

    let offsets = if let Some(co) = find(&st, b"stco") {
        let n = be32(d, co.body + 4)? as usize;
        if n > d.len() {
            return Err("chunk count past the file".into());
        }
        table_fits(&co, co.body + 8, 4, n)?;
        let mut v = Vec::with_capacity(n);
        for k in 0..n {
            v.push(be32(d, co.body + 8 + 4 * k)?);
        }
        Offsets::Short(v)
    } else {
        let co = find(&st, b"co64").ok_or("track without chunk offsets")?;
        let n = be32(d, co.body + 4)? as usize;
        if n > d.len() {
            return Err("chunk count past the file".into());
        }
        table_fits(&co, co.body + 8, 8, n)?;
        let mut v = Vec::with_capacity(n);
        for k in 0..n {
            v.push(be_sized(d, co.body + 8 + 8 * k, 8)?);
        }
        Offsets::Long(v)
    };
    Ok(SampleTables { sizes, fixed, count, runs, offsets })
}

impl SampleTables {
    /// Hands `each` the place of every sample in a file of `len` bytes, one at
    /// a time: holding them took a range per sample (HOL-SEC-302).
    fn walk(&self, len: usize, mut each: impl FnMut(Range<usize>) -> Result<(), String>) -> Result<(), String> {
        let (runs, offsets) = (&self.runs, &self.offsets);
        let mut sample = 0usize;
        for (k, &(first, per_chunk)) in runs.iter().enumerate() {
            if first == 0 {
                return Err("chunk numbers start at one".into());
            }
            let last = runs.get(k + 1).map(|n| n.0.saturating_sub(1)).unwrap_or(offsets.len() as u32);
            if per_chunk == 0 {
                // Runs may name the same chunks again, so walking an empty one
                // would cost runs times chunks; it only has to name chunks the
                // offset table holds (HOL-SEC-269).
                if first <= last && last as usize > offsets.len() {
                    return Err("chunk past the offset table".into());
                }
                continue;
            }
            for chunk in first..=last {
                let mut at = offsets.get(chunk as usize - 1).ok_or("chunk past the offset table")?;
                for _ in 0..per_chunk {
                    if sample >= self.count {
                        return Ok(());
                    }
                    let size = if self.fixed != 0 { self.fixed } else { *self.sizes.get(sample).ok_or("sample past the size table")? };
                    sample += 1;
                    let end = at.checked_add(u64::from(size)).filter(|e| *e <= len as u64).ok_or("sample past the file")?;
                    each(at as usize..end as usize)?;
                    at = end;
                }
            }
        }
        Ok(())
    }
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
    for b in top.iter() {
        if matches!(&b.kind, b"uuid" | b"udta" | b"gps ") {
            to_free(d, &b);
        }
    }
    // An image sequence keeps a movie beside its items, with tracks and user
    // data of its own, which 0.14 never walked (HOL-SEC-307).
    let mut budget = Budget::for_file(d.len());
    if let Some(moov) = find(&top, b"moov") {
        let fragmented = find(&top, b"moof").is_some();
        let tracks = fragment_tracks(d, &top)?;
        strip_moov(d, &moov, fragmented, &mut budget)?;
        strip_fragments(d, &top, &tracks, &mut budget)?;
    }
    let meta = find(&top, b"meta").ok_or("no meta box")?;
    let kids = boxes(d, meta.body + 4..meta.end, false)?;
    let Some(iinf) = find(&kids, b"iinf") else { return Ok(()) };
    let targets = metadata_items(d, &iinf)?;
    if targets.is_empty() {
        return Ok(());
    }
    let iloc = find(&kids, b"iloc").ok_or("metadata items without locations")?;
    let idat = find(&kids, b"idat").map(|b| b.body);
    // The extents are counted against the budget first, then zeroed from a
    // copy of the table as it was read: the zeroing may reach the table itself
    // (HOL-SEC-269), and a range per extent held four times the file.
    let read_to = item_extents(d, iloc.body, d.len(), idat, &targets, |r| budget.charge(&r))?;
    let table = d.get(iloc.body..read_to).ok_or("iloc read past the file")?.to_vec();
    let len = d.len();
    item_extents(&table, 0, len, idat, &targets, |r| zero(d, r))?;
    Ok(())
}

/// Ids of the items holding Exif or XMP.
fn metadata_items(d: &[u8], iinf: &Bx) -> Result<Vec<u32>, String> {
    let version = *d.get(iinf.body).ok_or("empty iinf")?;
    let first = iinf.body + 4 + if version == 0 { 2 } else { 4 };
    let mut out = Vec::new();
    for infe in boxes(d, first..iinf.end, false)?.iter() {
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

/// Walks an `iloc` whose body starts at `at` in `src` and hands `each` the
/// range, in a file of `len` bytes, of every extent of the given items.
/// Returns where in `src` the walk stopped reading.
fn item_extents(
    src: &[u8],
    at: usize,
    len: usize,
    idat: Option<usize>,
    ids: &[u32],
    mut each: impl FnMut(Range<usize>) -> Result<(), String>,
) -> Result<usize, String> {
    let version = *src.get(at).ok_or("empty iloc")?;
    let sizes = *src.get(at + 4).ok_or("truncated iloc")?;
    let more = *src.get(at + 5).ok_or("truncated iloc")?;
    let (offset_size, length_size) = ((sizes >> 4) as usize, (sizes & 0x0F) as usize);
    let base_size = (more >> 4) as usize;
    let index_size = if version >= 1 { (more & 0x0F) as usize } else { 0 };
    if [offset_size, length_size, base_size, index_size].iter().any(|s| ![0, 4, 8].contains(s)) {
        return Err("iloc field size".into());
    }
    let mut i = at + 6;
    let count = if version < 2 {
        i += 2;
        be16(src, i - 2)? as usize
    } else {
        i += 4;
        be32(src, i - 4)? as usize
    };
    let ids: std::collections::HashSet<u32> = ids.iter().copied().collect();
    for _ in 0..count {
        let id = if version < 2 {
            i += 2;
            be16(src, i - 2)? as u32
        } else {
            i += 4;
            be32(src, i - 4)?
        };
        let method = if version >= 1 {
            i += 2;
            be16(src, i - 2)? & 0x0F
        } else {
            0
        };
        i += 2; // data_reference_index
        let base = be_sized(src, i, base_size)?;
        i += base_size;
        let extents = be16(src, i)? as usize;
        i += 2;
        let wanted = ids.contains(&id);
        // An extent with no fields takes no bytes, so an item may list 65535 of
        // them for free; each reads as offset 0, length 0 (HOL-SEC-269).
        if index_size + offset_size + length_size == 0 {
            if wanted && extents > 0 {
                return Err("metadata item runs to the end of the file".into());
            }
            continue;
        }
        for _ in 0..extents {
            i += index_size;
            let off = be_sized(src, i, offset_size)?;
            i += offset_size;
            let size = be_sized(src, i, length_size)?;
            i += length_size;
            if !wanted {
                continue;
            }
            if size == 0 {
                return Err("metadata item runs to the end of the file".into());
            }
            let origin = match method {
                0 => 0u64,
                1 => idat.ok_or("idat item without idat")? as u64,
                _ => return Err("metadata item built from other items".into()),
            };
            let start = origin.checked_add(base).and_then(|s| s.checked_add(off)).ok_or("extent overflow")?;
            let end = start.checked_add(size).filter(|e| *e <= len as u64).ok_or("extent past the file")?;
            each(start as usize..end as usize)?;
        }
    }
    Ok(i)
}

// ── Matroska and WebM ───────────────────────────────────────────────────────

const EBML_HEADER: u32 = 0x1A45_DFA3;
const SEGMENT: u32 = 0x1853_8067;
const CLUSTER: u32 = 0x1F43_B675;
const INFO: u32 = 0x1549_A966;
const TAGS: u32 = 0x1254_C367;
const ATTACHMENTS: u32 = 0x1941_A469;
const CHAPTERS: u32 = 0x1043_A770;
const DATE_UTC: u32 = 0x4461;
const TITLE: u32 = 0x7BA9;
/// Elements that sit directly in a Segment, so one of them ends an
/// unknown-size Cluster.
const SEGMENT_LEVEL: &[u32] =
    &[0x114D_9B74, INFO, 0x1654_AE6B, CLUSTER, 0x1C53_BB6B, ATTACHMENTS, CHAPTERS, TAGS];

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
            // Attached files keep their own Exif, and chapters may name a
            // place (HOL-SEC-306).
            TAGS | ATTACHMENTS | CHAPTERS => void(d, i, end),
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
    strip_riff_chunks(d, 12, end, 0)
}

/// How deep header lists may nest. A real AVI nests them once, and each level
/// is a call, so a crafted file must not choose the depth (HOL-SEC-268).
const MAX_LIST_DEPTH: usize = 16;

/// Turns the INFO list and the capture date into JUNK chunks of the same size.
fn strip_riff_chunks(d: &mut [u8], from: usize, to: usize, depth: usize) -> Result<(), String> {
    let mut i = from;
    while i + 8 <= to {
        let len = le32(d, i + 4)? as usize;
        let end = (i + 8).checked_add(len).filter(|e| *e <= to).ok_or("chunk overruns its list")?;
        let is_info = &d[i..i + 4] == b"LIST" && d.get(i + 8..i + 12) == Some(b"INFO".as_slice());
        if is_info || &d[i..i + 4] == b"IDIT" {
            d[i..i + 4].copy_from_slice(b"JUNK");
            d[i + 8..end].fill(0);
        } else if &d[i..i + 4] == b"LIST" && d.get(i + 8..i + 12) == Some(b"hdrl".as_slice()) {
            if depth >= MAX_LIST_DEPTH {
                return Err("header lists nest too deep".into());
            }
            strip_riff_chunks(d, i + 12, end, depth + 1)?;
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
    // An entry past the block cannot match, and a crafted count walked 65535
    // of them for every EXIF chunk of a WebP (HOL-SEC-301).
    (0..n)
        .map(|k| ifd + 2 + 12 * k)
        .take_while(|&e| e + 2 <= tiff.len())
        .find(|&e| rd16(e) == Some(0x0112))
        .and_then(|e| rd16(e + 8))
        .filter(|v| (1..=8).contains(v))
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

    pub(crate) fn ebml(id: &[u8], body: &[u8]) -> Vec<u8> {
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

    /// A two-frame GIF with a loop count, an XMP packet and a comment holding
    /// the location, and a plain text extension the strip keeps.
    pub(crate) fn gif_with_location() -> Vec<u8> {
        let mut g = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xFF\xFF\xFF".to_vec();
        g.extend_from_slice(&[&[0x21, 0xFF, 11][..], b"NETSCAPE2.0", &[3, 1, 0, 0, 0]].concat());
        g.extend_from_slice(&[&[0x21, 0xFF, 11][..], b"XMP DataXMP", &[LOCATION.len() as u8], LOCATION, &[0]].concat());
        g.extend_from_slice(&[&[0x21, 0xFE, LOCATION.len() as u8][..], LOCATION, &[0]].concat());
        let frame = [0x21, 0xF9, 4, 0, 10, 0, 0, 0, 0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 0x01, 0];
        g.extend_from_slice(&frame);
        g.extend_from_slice(&[0x21, 0x01, 12, 0, 0, 0, 0, 1, 0, 1, 0, 1, 1, 0, 1, 3, b'h', b'i', b'!', 0]);
        g.extend_from_slice(&frame);
        g.push(0x3B);
        g
    }

    /// GIFs cut inside a last block the strip keeps: an unknown extension and
    /// the loop count, each claiming more bytes than are left (HOL-SEC-267).
    pub(crate) fn gifs_with_a_kept_block_past_the_end() -> [Vec<u8>; 2] {
        let gif = gif_with_location();
        let body = &gif[..gif.len() - 1];
        [
            [body, &[0x21, 0x01, 200, 1, 2, 3]].concat(),
            [body, &[0x21, 0xFF, 11], b"NETSCAPE2.0", &[200, 1, 0]].concat(),
        ]
    }

    /// An AVI whose header list holds another header list `depth` times over
    /// (HOL-SEC-268).
    pub(crate) fn avi_nested(depth: usize) -> Vec<u8> {
        let inner = riff(b"avih", &[0; 56]);
        let total = 12 + 12 * depth + inner.len();
        let mut v = Vec::with_capacity(total);
        v.extend_from_slice(b"RIFF");
        v.extend_from_slice(&((total - 8) as u32).to_le_bytes());
        v.extend_from_slice(b"AVI ");
        for k in 0..depth {
            v.extend_from_slice(b"LIST");
            v.extend_from_slice(&((total - 12 * (k + 1) - 8) as u32).to_le_bytes());
            v.extend_from_slice(b"hdrl");
        }
        v.extend_from_slice(&inner);
        v
    }

    /// An mp4 whose timed GPS track has `runs` runs of empty chunks, every
    /// other one starting at the first of `chunks` chunks (HOL-SEC-269).
    pub(crate) fn mp4_with_empty_chunk_runs(runs: u32, chunks: u32) -> Vec<u8> {
        let mut stsc = runs.to_be_bytes().to_vec();
        for k in 0..runs {
            let first = if k % 2 == 0 { 1 } else { chunks + 1 };
            stsc.extend_from_slice(&first.to_be_bytes());
            stsc.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 1]);
        }
        let stco = full(b"stco", 0, &[&chunks.to_be_bytes()[..], &vec![0u8; 4 * chunks as usize]].concat());
        let stbl = bx(b"stbl", &[full(b"stsz", 0, &[0u8; 8]), full(b"stsc", 0, &stsc), stco].concat());
        let hdlr = full(b"hdlr", 0, &[&[0u8; 4][..], b"meta", &[0; 12]].concat());
        let trak = bx(b"trak", &bx(b"mdia", &[hdlr, bx(b"minf", &stbl)].concat()));
        [bx(b"ftyp", b"isom\0\0\0\0"), bx(b"moov", &trak)].concat()
    }

    /// A HEIC whose `items` items (none of them the Exif item) each list
    /// 65535 extents written with no fields (HOL-SEC-269).
    pub(crate) fn heic_with_empty_extents(items: u16) -> Vec<u8> {
        let mut iloc = vec![0x00, 0x00];
        iloc.extend_from_slice(&items.to_be_bytes());
        for id in 0..items {
            iloc.extend_from_slice(&(id % 60_000 + 3).to_be_bytes());
            iloc.extend_from_slice(&[0, 0, 0xFF, 0xFF]);
        }
        let infe = full(b"infe", 2, &[&[0, 2, 0, 0][..], b"Exif", b"\0"].concat());
        let iinf = full(b"iinf", 0, &[&[0, 1][..], &infe].concat());
        let meta = full(b"meta", 0, &[iinf, full(b"iloc", 0, &iloc)].concat());
        [bx(b"ftyp", b"heic\0\0\0\0mif1heic"), meta].concat()
    }

    /// A HEIC with `ids` Exif items and `items` other items of `extents`
    /// extents each, located by a version 2 `iloc` (HOL-SEC-269).
    pub(crate) fn heic_with_many_exif_items(ids: u16, items: u32, extents: u16) -> Vec<u8> {
        let mut infes = ids.to_be_bytes().to_vec();
        for id in 1..=ids {
            infes.extend_from_slice(&full(b"infe", 2, &[&id.to_be_bytes()[..], &[0, 0], b"Exif", b"\0"].concat()));
        }
        let mut iloc = vec![0x04, 0x00];
        iloc.extend_from_slice(&items.to_be_bytes());
        for k in 0..items {
            iloc.extend_from_slice(&(100_000 + k).to_be_bytes());
            iloc.extend_from_slice(&[0, 0, 0, 0]);
            iloc.extend_from_slice(&extents.to_be_bytes());
            iloc.extend_from_slice(&[0, 0, 0, 1].repeat(extents as usize));
        }
        let meta = full(b"meta", 0, &[full(b"iinf", 0, &infes), full(b"iloc", 2, &iloc)].concat());
        [bx(b"ftyp", b"heic\0\0\0\0mif1heic"), meta].concat()
    }

    /// A WebP of nothing but `chunks` EXIF chunks, each a TIFF header whose
    /// first IFD claims 18761 entries (HOL-SEC-301).
    pub(crate) fn webp_with_many_exif_chunks(chunks: usize) -> Vec<u8> {
        let chunk = [b"EXIF".as_slice(), &8u32.to_le_bytes(), b"II*\0\0\0\0\0"].concat();
        let body = [b"WEBP".as_slice(), &chunk.repeat(chunks)].concat();
        [b"RIFF".as_slice(), &(body.len() as u32).to_le_bytes(), &body].concat()
    }

    /// An mp4 whose timed GPS track holds `samples` samples of one byte each,
    /// named by a fixed-size sample table (HOL-SEC-302).
    pub(crate) fn mp4_with_one_byte_samples(samples: u32) -> Vec<u8> {
        let ftyp = bx(b"ftyp", b"isom\0\0\0\0");
        let at = ftyp.len() as u32 + 8;
        let stsz = full(b"stsz", 0, &[1u32.to_be_bytes(), samples.to_be_bytes()].concat());
        let stsc = full(b"stsc", 0, &[1u32.to_be_bytes(), 1u32.to_be_bytes(), samples.to_be_bytes(), 1u32.to_be_bytes()].concat());
        let stco = full(b"stco", 0, &[1u32.to_be_bytes(), at.to_be_bytes()].concat());
        let hdlr = full(b"hdlr", 0, &[&[0u8; 4][..], b"meta", &[0; 12]].concat());
        let trak = bx(b"trak", &bx(b"mdia", &[hdlr, bx(b"minf", &bx(b"stbl", &[stsz, stsc, stco].concat()))].concat()));
        [ftyp, bx(b"mdat", &vec![7u8; samples as usize]), bx(b"moov", &trak)].concat()
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
        let kinds: Vec<[u8; 4]> = kids.iter().map(|b| b.kind).collect();
        assert_eq!(kinds, [*b"mvhd", *b"trak", *b"free", *b"free", *b"free"], "GPS track, udta and meta became padding");
        let trak = kids.get(1).unwrap();
        let mdia = find(&boxes(&after, trak.body..trak.end, false).unwrap(), b"mdia").unwrap();
        let mut ranges = Vec::new();
        let tables = sample_tables(&after, &boxes(&after, mdia.body..mdia.end, false).unwrap()).unwrap();
        tables.walk(after.len(), |r| {
            ranges.push(r);
            Ok(())
        })
        .unwrap();
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

    /// `f`'s answer, if it comes within `secs` on a thread of its own.
    fn within<T: Send + 'static>(secs: u64, f: impl FnOnce() -> T + Send + 'static) -> Option<T> {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .stack_size(1 << 20)
            .spawn(move || {
                let _ = tx.send(f());
            })
            .expect("spawn");
        rx.recv_timeout(std::time::Duration::from_secs(secs)).ok()
    }

    /// HOL-SEC-267: a GIF block the strip keeps that runs past the end of the
    /// file is refused; 0.14 panicked slicing it.
    #[test]
    fn a_kept_gif_block_past_the_end_is_refused() {
        for gif in gifs_with_a_kept_block_past_the_end() {
            assert!(strip_for_send("gif", gif).is_err());
        }
        let gif = gif_with_location();
        let out = strip_for_send("gif", gif.clone()).expect("a whole GIF strips");
        assert!(!holds(&out, LOCATION), "the comment and the XMP packet went");
        assert!(holds(&out, b"NETSCAPE2.0") && holds(&out, b"hi!"), "the loop count and the text stay");
        // A dropped block cut short still ends the copy where 0.14 ended it.
        let cut = [&gif[..gif.len() - 1], &[0x21, 0xFE, 200, 1, 2]].concat();
        assert_eq!(strip_for_send("gif", cut).unwrap(), out[..out.len() - 1]);
    }

    /// HOL-SEC-268: AVI header lists nest at most 16 deep; 0.14 recursed into
    /// each one and a crafted file overflowed the stack.
    #[test]
    fn a_deeply_nested_avi_is_refused() {
        assert!(strip_for_send("avi", avi_nested(16)).is_ok(), "within the bound it strips");
        assert!(strip_for_send("avi", avi_nested(17)).is_err());
        let deep = avi_nested(200_000);
        let answer = within(20, move || strip_for_send("avi", deep).is_err());
        assert_eq!(answer, Some(true), "refused on a 1 MiB stack");
    }

    /// HOL-SEC-269: sample tables and item locations that cost 0.14 billions
    /// of steps take one pass, with 0.14's answer.
    #[test]
    fn crafted_tables_take_one_pass() {
        let mp4 = mp4_with_empty_chunk_runs(150_000, 150_000);
        let out = within(20, move || strip_for_send("mp4", mp4)).expect("runs of empty chunks take one pass");
        assert!(!holds(&out.expect("an empty GPS track strips"), b"trak"), "the track went");

        let heic = heic_with_empty_extents(50_000);
        let out = within(20, move || strip_for_send("heic", heic).is_ok());
        assert_eq!(out, Some(true), "extents with no fields take one pass");

        let heic = heic_with_many_exif_items(60_000, 4, 0xFFFF);
        let out = within(20, move || strip_for_send("heic", heic).is_ok());
        assert_eq!(out, Some(true), "each item is looked up once, not per extent");
        let heic = heic_with_many_exif_items(60_000, 300_000, 1);
        let out = within(20, move || strip_for_send("heic", heic).is_ok());
        assert_eq!(out, Some(true), "each item is looked up in a set");

        // An empty run naming a chunk past the offset table is refused, and so
        // is the Exif item written with no fields, as in 0.14.
        let mut bad = mp4_with_empty_chunk_runs(2, 4);
        let at = bad.windows(4).position(|w| w == b"stsc").unwrap() + 24;
        bad[at..at + 4].copy_from_slice(&6u32.to_be_bytes());
        assert!(strip_for_send("mp4", bad).is_err());
        let mut exif = heic_with_empty_extents(1);
        let at = exif.windows(4).position(|w| w == b"iloc").unwrap() + 12;
        exif[at..at + 2].copy_from_slice(&[0, 2]);
        assert!(strip_for_send("heic", exif).is_err());

        // Empty runs that name no chunk, an Exif item listing no extent, and
        // extents of index fields alone pass, as in 0.14.
        let mut fine = mp4_with_empty_chunk_runs(2, 4);
        let at = fine.windows(4).position(|w| w == b"stsc").unwrap() + 12;
        fine[at..at + 4].copy_from_slice(&9u32.to_be_bytes());
        fine[at + 12..at + 16].copy_from_slice(&7u32.to_be_bytes());
        assert!(strip_for_send("mp4", fine).is_ok());
        let mut none = heic_with_empty_extents(1);
        let at = none.windows(4).position(|w| w == b"iloc").unwrap() + 12;
        none[at..at + 6].copy_from_slice(&[0, 2, 0, 0, 0, 0]);
        assert!(strip_for_send("heic", none).is_ok());
        let infe = full(b"infe", 2, &[&[0, 2, 0, 0][..], b"Exif", b"\0"].concat());
        let items = [&[0, 5, 0, 0, 0, 0, 0, 2][..], &[0, 2, 0, 0, 0, 0, 0, 1], &[0, 2, 0, 0, 0, 0, 0, 0]].concat();
        let iloc = full(b"iloc", 1, &[&[0x00, 0x04, 0, 2][..], &items].concat());
        let meta = full(b"meta", 0, &[full(b"iinf", 0, &[&[0, 1][..], &infe].concat()), iloc].concat());
        assert!(strip_for_send("heic", [bx(b"ftyp", b"heic\0\0\0\0mif1heic"), meta].concat()).is_ok());
    }

    /// HOL-SEC-301: a WebP's EXIF chunks cost what they hold; 0.14 walked up
    /// to 65535 IFD entries past the end of each one.
    #[test]
    fn a_webp_of_many_exif_chunks_takes_one_pass() {
        let webp = webp_with_many_exif_chunks(500_000);
        let out = within(20, move || strip_for_send("webp", webp).map(|o| o.len()));
        assert_eq!(out, Some(Ok(12)), "every EXIF chunk goes, in one pass");
        // An orientation past an IFD the count overstates is still found.
        let mut tiff = exif_with_gps(6);
        tiff[8..10].copy_from_slice(&0xFFFFu16.to_le_bytes());
        assert_eq!(exif_orientation(&tiff), Some(6));
        assert_eq!(exif_orientation(&tiff[..20]), Some(6), "an entry cut after its value still counts");
    }

    /// HOL-SEC-302: a fixed-size sample table names up to a sample per byte,
    /// and the strip holds none of them; 0.14 held about 24 bytes a sample.
    #[test]
    fn a_fixed_size_sample_table_is_walked_without_holding_it() {
        let mp4 = mp4_with_one_byte_samples(4 << 20);
        let len = mp4.len();
        let (out, peak) = within(20, move || crate::test_alloc::peak_during(|| strip_for_send("mp4", mp4))).expect("in time");
        let out = out.expect("a GPS track of one-byte samples strips");
        assert_eq!(out.len(), len);
        assert!(out.windows(4).all(|w| w != [7; 4]), "every sample was zeroed");
        assert!(peak < len / 4, "held {peak} bytes stripping a {len} byte file");
    }

    /// HOL-SEC-304: a GIF cut inside its header or colour table is refused;
    /// 0.14 passed it on unchanged, whatever it held.
    #[test]
    fn a_gif_cut_inside_its_header_is_refused() {
        let gif = gif_with_location();
        for cut in [6, 12, 13, 18] {
            assert!(strip_for_send("gif", gif[..cut].to_vec()).is_err(), "cut at {cut}");
        }
        let mut big_table = gif.clone();
        big_table[10] = 0x87;
        assert!(strip_for_send("gif", [&big_table[..], LOCATION].concat()).is_err(), "a colour table the file does not hold");
        assert_eq!(strip_for_send("gif", gif[..19].to_vec()).unwrap(), gif[..19], "a whole header and table strip");
    }

    /// HOL-SEC-269: the samples and extents to zero may cover the file twice
    /// over, never more.
    #[test]
    fn metadata_may_cover_the_file_at_most_twice() {
        assert!(strip_for_send("mp4", mp4_with_shared_chunk_offsets(2, 1 << 20)).is_ok());
        assert!(strip_for_send("mp4", mp4_with_shared_chunk_offsets(3, 1 << 20)).is_err());
        assert!(strip_for_send("heic", heic_with_overlapping_exif_extents(1, 2, 1 << 20, 1 << 20)).is_ok());
        assert!(strip_for_send("heic", heic_with_overlapping_exif_extents(1, 3, 1 << 20, 1 << 20)).is_err());
    }

    /// HOL-SEC-302: each sample table must fit its own box; one entry more is
    /// refused, whichever table it is.
    #[test]
    fn a_sample_table_longer_than_its_box_is_refused() {
        let at = |d: &[u8], kind: &[u8; 4]| d.windows(4).position(|w| w == kind).unwrap() + 4;
        let honest = mp4_with_one_byte_samples(16);
        assert!(strip_for_send("mp4", honest.clone()).is_ok());
        for (kind, count_at) in [(b"stsc", 4), (b"stco", 4)] {
            let mut d = honest.clone();
            let p = at(&d, kind) + count_at;
            let n = u32::from_be_bytes(d[p..p + 4].try_into().unwrap()) + 1;
            d[p..p + 4].copy_from_slice(&n.to_be_bytes());
            assert!(strip_for_send("mp4", d).is_err(), "{}", String::from_utf8_lossy(kind));
        }
        // Variable sizes: one more than the box holds.
        let mut d = mp4_with_chunk_runs();
        let p = at(&d, b"stsz") + 8;
        d[p..p + 4].copy_from_slice(&4u32.to_be_bytes());
        assert!(strip_for_send("mov", d).is_err(), "stsz");
        let co64 = mp4_with_co64(16);
        assert!(strip_for_send("mp4", co64.clone()).is_ok());
        let mut d = co64;
        let p = at(&d, b"co64") + 4;
        d[p..p + 4].copy_from_slice(&2u32.to_be_bytes());
        assert!(strip_for_send("mp4", d).is_err(), "co64");
    }

    /// HOL-SEC-302: a sample table whose count reaches past its box to the end
    /// of the file is refused before any of it is read, whichever table it is.
    #[test]
    fn a_sample_table_reaching_past_its_box_holds_nothing() {
        for table in [b"stsz", b"stsc", b"stco", b"co64"] {
            let co = if table == b"co64" {
                full(b"co64", 0, &[&1u32.to_be_bytes()[..], &0u64.to_be_bytes()].concat())
            } else {
                full(b"stco", 0, &[1u32.to_be_bytes(), 0u32.to_be_bytes()].concat())
            };
            let stsz = full(b"stsz", 0, &[1u32.to_be_bytes(), 1u32.to_be_bytes()].concat());
            let stsc = full(b"stsc", 0, &[1u32.to_be_bytes(), 1u32.to_be_bytes(), 1u32.to_be_bytes(), 1u32.to_be_bytes()].concat());
            let mut d = [bx(b"ftyp", b"isom\0\0\0\0"), bx(b"moov", &meta_trak([stsz, stsc, co].concat())), bx(b"free", &vec![0x33u8; 4 << 20])].concat();
            let body = body_of(&d, table, 0);
            let (count_at, first, width) = match table {
                b"stsz" => (8, 12, 4),
                b"stsc" => (4, 8, 12),
                b"stco" => (4, 8, 4),
                _ => (4, 8, 8),
            };
            if table == b"stsz" {
                d[body + 4..body + 8].copy_from_slice(&0u32.to_be_bytes());
            }
            let n = ((d.len() - (body + first)) / width) as u32;
            d[body + count_at..body + count_at + 4].copy_from_slice(&n.to_be_bytes());
            let len = d.len() as i64;
            let (refused, peak) = peak_of(move || strip_for_send("mp4", d).is_err());
            let name = String::from_utf8_lossy(table);
            assert!(refused, "{name}");
            assert!(peak < len / 8, "{name}: held {peak} bytes stripping a {len} byte file");
        }
    }

    /// HOL-SEC-303: a box list takes exactly the room its boxes need, so a
    /// count just past a power of two does not double it.
    #[test]
    fn a_box_list_takes_the_room_it_holds() {
        let mp4 = mp4_of_empty_boxes((512 << 10) + 1);
        let len = mp4.len() as i64;
        let (_, peak) = peak_of(move || strip_for_send("mp4", mp4).is_ok());
        assert!(peak < 2 * len, "held {peak} bytes stripping a {len} byte file");
    }

    /// A box written with a 64-bit size keeps its whole header when freed.
    #[test]
    fn a_box_with_a_64_bit_size_keeps_its_header() {
        let mut udta = vec![0, 0, 0, 1];
        udta.extend_from_slice(b"udta");
        udta.extend_from_slice(&(16 + LOCATION.len() as u64).to_be_bytes());
        udta.extend_from_slice(LOCATION);
        let out = strip_for_send("mp4", [mp4_with_location(), udta.clone()].concat()).unwrap();
        let tail = &out[out.len() - udta.len()..];
        assert_eq!(tail[..16], [&[0, 0, 0, 1][..], b"free", &udta[8..16]].concat());
        assert!(tail[16..].iter().all(|b| *b == 0));
    }

    /// `mp4_with_one_byte_samples` with 64-bit chunk offsets.
    fn mp4_with_co64(samples: u32) -> Vec<u8> {
        let mp4 = mp4_with_one_byte_samples(samples);
        let p = mp4.windows(4).position(|w| w == b"stco").unwrap() - 4;
        let at = u32::from_be_bytes(mp4[p + 16..p + 20].try_into().unwrap());
        let co64 = full(b"co64", 0, &[&1u32.to_be_bytes()[..], &(u64::from(at)).to_be_bytes()].concat());
        // The box grows by 4 bytes: every enclosing size grows with it.
        let mut out = [&mp4[..p], &co64[..], &mp4[p + 20..]].concat();
        for kind in [b"moov", b"trak", b"mdia", b"minf", b"stbl"] {
            let q = out.windows(4).position(|w| w == kind).unwrap() - 4;
            let n = u32::from_be_bytes(out[q..q + 4].try_into().unwrap()) + 4;
            out[q..q + 4].copy_from_slice(&n.to_be_bytes());
        }
        out
    }

    // Review round (fix-media-strip): HOL-SEC-269, 302, 303.

    fn meta_trak(stbl: Vec<u8>) -> Vec<u8> {
        let hdlr = full(b"hdlr", 0, &[&[0u8; 4][..], b"meta", &[0; 12]].concat());
        bx(b"trak", &bx(b"mdia", &[hdlr, bx(b"minf", &bx(b"stbl", &stbl))].concat()))
    }

    /// A timed metadata track whose `chunks` chunks all start at the same offset,
    /// each one sample of `sample` bytes: every sample zeroes the same bytes.
    fn mp4_with_shared_chunk_offsets(chunks: u32, sample: u32) -> Vec<u8> {
        let ftyp = bx(b"ftyp", b"isom\0\0\0\0");
        let at = ftyp.len() as u32 + 8;
        let stsz = full(b"stsz", 0, &[sample.to_be_bytes(), chunks.to_be_bytes()].concat());
        let stsc = full(b"stsc", 0, &[1u32.to_be_bytes(), 1u32.to_be_bytes(), 1u32.to_be_bytes(), 1u32.to_be_bytes()].concat());
        let stco = full(b"stco", 0, &[&chunks.to_be_bytes()[..], &at.to_be_bytes().repeat(chunks as usize)].concat());
        [ftyp, bx(b"mdat", &vec![7u8; sample as usize]), bx(b"moov", &meta_trak([stsz, stsc, stco].concat()))].concat()
    }

    /// A HEIC whose one Exif item is listed `items` times, each with `extents`
    /// extents of `len` bytes from offset 0 (no offset field), then `pad` bytes.
    fn heic_with_overlapping_exif_extents(items: u16, extents: u16, len: u32, pad: usize) -> Vec<u8> {
        let infe = full(b"infe", 2, &[&[0, 2, 0, 0][..], b"Exif", b"\0"].concat());
        let iinf = full(b"iinf", 0, &[&[0, 1][..], &infe].concat());
        let mut iloc = vec![0x04, 0x00];
        iloc.extend_from_slice(&items.to_be_bytes());
        for _ in 0..items {
            iloc.extend_from_slice(&[0, 2, 0, 0]);
            iloc.extend_from_slice(&extents.to_be_bytes());
            iloc.extend_from_slice(&len.to_be_bytes().repeat(extents as usize));
        }
        let meta = full(b"meta", 0, &[iinf, full(b"iloc", 0, &iloc)].concat());
        [bx(b"ftyp", b"heic\0\0\0\0mif1heic"), meta, bx(b"mdat", &vec![1u8; pad])].concat()
    }

    fn body_of(d: &[u8], kind: &[u8; 4], nth: usize) -> usize {
        let mut seen = 0;
        for p in 0..d.len() - 4 {
            if &d[p..p + 4] == kind {
                if seen == nth {
                    return p + 4;
                }
                seen += 1;
            }
        }
        panic!("no {:?}", kind);
    }

    /// One timed metadata track whose variable sizes, chunk runs and chunk
    /// offsets each claim every entry up to the end of the file, so the three
    /// tables are read over the same `tail` bytes, far past their own boxes.
    fn mp4_with_tables_past_their_boxes(tail: usize) -> Vec<u8> {
        let stsz = full(b"stsz", 0, &[0u32.to_be_bytes(), 0u32.to_be_bytes()].concat());
        let stsc = full(b"stsc", 0, &0u32.to_be_bytes());
        let stco = full(b"stco", 0, &0u32.to_be_bytes());
        let mut d = [bx(b"ftyp", b"isom\0\0\0\0"), bx(b"moov", &meta_trak([stsz, stsc, stco].concat())), bx(b"free", &vec![0x11u8; tail])].concat();
        let len = d.len();
        let (sz, sc, co) = (body_of(&d, b"stsz", 0), body_of(&d, b"stsc", 0), body_of(&d, b"stco", 0));
        d[sz + 8..sz + 12].copy_from_slice(&(((len - (sz + 12)) / 4) as u32).to_be_bytes());
        d[sc + 4..sc + 8].copy_from_slice(&(((len - (sc + 8)) / 12) as u32).to_be_bytes());
        d[co + 4..co + 8].copy_from_slice(&(((len - (co + 8)) / 4) as u32).to_be_bytes());
        d
    }

    /// `tracks` timed metadata tracks, each with one sample and a chunk offset
    /// table whose count reaches the end of the file: each track re-reads the
    /// same `tail` bytes.
    fn mp4_with_many_tracks_reading_one_tail(tracks: usize, tail: usize) -> Vec<u8> {
        let ftyp = bx(b"ftyp", b"isom\0\0\0\0");
        let mdat = bx(b"mdat", &[5u8; 64]);
        let at = (ftyp.len() + 8) as u32;
        let trak = || {
            let stsz = full(b"stsz", 0, &[1u32.to_be_bytes(), 1u32.to_be_bytes()].concat());
            let stsc = full(b"stsc", 0, &[1u32.to_be_bytes(), 1u32.to_be_bytes(), 1u32.to_be_bytes(), 1u32.to_be_bytes()].concat());
            let stco = full(b"stco", 0, &[0u32.to_be_bytes(), at.to_be_bytes()].concat());
            meta_trak([stsz, stsc, stco].concat())
        };
        let traks: Vec<u8> = (0..tracks).flat_map(|_| trak()).collect();
        let mut d = [ftyp, mdat, bx(b"moov", &traks), bx(b"free", &vec![0x22u8; tail])].concat();
        let len = d.len();
        let bodies: Vec<usize> = d.windows(4).enumerate().filter(|(_, w)| *w == b"stco").map(|(p, _)| p + 4).collect();
        assert_eq!(bodies.len(), tracks);
        for co in bodies {
            d[co + 4..co + 8].copy_from_slice(&(((len - (co + 8)) / 4) as u32).to_be_bytes());
        }
        d
    }

    /// A moov holding nothing but `n` empty 8-byte boxes.
    fn mp4_of_empty_boxes(n: usize) -> Vec<u8> {
        let kids: Vec<u8> = (0..n).flat_map(|_| bx(b"free", &[])).collect();
        [bx(b"ftyp", b"isom\0\0\0\0"), bx(b"moov", &kids)].concat()
    }

    fn peak_of<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> (T, i64) {
        let (out, peak) = within(600, move || crate::test_alloc::peak_during(f)).expect("finished");
        (out, peak as i64)
    }

    // ── failing tests ──────────────────────────────────────────────────────────

    #[test]
    fn rev_a_metadata_track_whose_chunks_share_an_offset_takes_one_pass() {
        // 8 MiB file: 2^20 chunks, each one 4 MiB sample over the same bytes.
        let mp4 = mp4_with_shared_chunk_offsets(1 << 20, 4 << 20);
        let out = within(20, move || strip_for_send("mp4", mp4).is_ok());
        assert!(out.is_some(), "every sample zeroes the same 4 MiB: the strip is still running after 20 s");
    }

    #[test]
    fn rev_a_heic_whose_exif_extents_overlap_takes_one_pass() {
        // ~8 MiB file: 2^20 extents of the Exif item, each the first 4 MiB.
        let heic = heic_with_overlapping_exif_extents(16, 0xFFFF, 4 << 20, 4 << 20);
        let out = within(20, move || strip_for_send("heic", heic).is_ok());
        assert!(out.is_some(), "every extent zeroes the same 4 MiB: the strip is still running after 20 s");
    }

    #[test]
    fn rev_many_metadata_tracks_cost_what_the_file_holds() {
        // ~6 MiB file: 20,000 tracks, each reading the same 3 MiB tail as offsets.
        let mp4 = mp4_with_many_tracks_reading_one_tail(20_000, 3 << 20);
        let out = within(20, move || strip_for_send("mp4", mp4).is_ok());
        assert!(out.is_some(), "each track re-reads the tail past its own box: still running after 20 s");
    }

    #[test]
    fn rev_sample_tables_hold_at_most_twice_the_file() {
        let mp4 = mp4_with_tables_past_their_boxes(4 << 20);
        let len = mp4.len() as i64;
        let (_, peak) = peak_of(move || strip_for_send("mp4", mp4).is_ok());
        assert!(peak < 2 * len, "held {peak} bytes ({}x) stripping a {len} byte file", peak as f64 / len as f64);
    }

    #[test]
    fn rev_a_box_list_holds_at_most_twice_the_file() {
        let mp4 = mp4_of_empty_boxes(512 << 10);
        let len = mp4.len() as i64;
        let (_, peak) = peak_of(move || strip_for_send("mp4", mp4).is_ok());
        assert!(peak < 2 * len, "held {peak} bytes ({}x) stripping a {len} byte file", peak as f64 / len as f64);
    }

    #[test]
    fn rev_a_heic_extent_list_holds_at_most_twice_the_file() {
        // 2^20 one-byte extents of the Exif item, disjoint enough to finish.
        let heic = heic_with_overlapping_exif_extents(16, 0xFFFF, 1, 16);
        let len = heic.len() as i64;
        let (_, peak) = peak_of(move || strip_for_send("heic", heic).is_ok());
        assert!(peak < 2 * len, "held {peak} bytes ({}x) stripping a {len} byte file", peak as f64 / len as f64);
    }

    /// A fragmented mp4: a video track and a GPS track, one sample each in the
    /// `mdat` after one `moof`. `mode` picks how the GPS fragment names its
    /// data: 0 its `moof` as base plus a data offset, 1 an explicit base offset
    /// (the `moof` start, written out) plus a data offset,
    /// 2 no base at all (after the video fragment's data), 3 a sample size from
    /// `trex`, 4 no sample size anywhere. Returns the file and the GPS sample.
    fn fragmented_mp4_with_gps(mode: u8) -> (Vec<u8>, Range<usize>) {
        let video = b"VIDEO-FRAGMENT".to_vec();
        let gps = [b"GPS ".as_slice(), LOCATION].concat();
        let (vlen, glen) = (video.len() as u32, gps.len() as u32);
        let flagged = |kind: &[u8; 4], flags: u32, body: &[u8]| bx(kind, &[&flags.to_be_bytes()[..], body].concat());
        let tkhd = |id: u8| full(b"tkhd", 0, &[&[0u8; 8][..], &[0, 0, 0, id], &[0; 68]].concat());
        let hdlr = |h: &[u8; 4]| full(b"hdlr", 0, &[&[0u8; 4][..], h, &[0; 12]].concat());
        let trak = |id: u8, h: &[u8; 4]| bx(b"trak", &[tkhd(id), bx(b"mdia", &hdlr(h))].concat());
        let trex = |id: u8, size: u32| full(b"trex", 0, &[&[0, 0, 0, id][..], &[0, 0, 0, 1], &[0; 4], &size.to_be_bytes(), &[0; 4]].concat());
        let mut mvex = trex(1, 0);
        if mode != 4 {
            mvex.extend(trex(2, if mode == 3 { glen } else { 0 }));
        }
        let ftyp = bx(b"ftyp", b"iso5\0\0\0\0iso5");
        let moov = bx(b"moov", &[full(b"mvhd", 0, &[0; 96]), trak(1, b"vide"), trak(2, b"meta"), bx(b"mvex", &mvex)].concat());
        let at = (ftyp.len() + moov.len()) as u32;
        let moof = |data: u32| {
            // The video run's records hold a duration and a size.
            let vbase = if mode == 2 { 0 } else { 0x02_0000 };
            let vtraf = [flagged(b"tfhd", vbase, &[0, 0, 0, 1]), flagged(b"trun", 0x301, &[&1u32.to_be_bytes()[..], &data.to_be_bytes(), &[0, 0, 0, 1], &vlen.to_be_bytes()].concat())].concat();
            let gtraf = match mode {
                0 => [flagged(b"tfhd", 0x02_0010, &[&[0, 0, 0, 2][..], &glen.to_be_bytes()].concat()), flagged(b"trun", 0x001, &[&1u32.to_be_bytes()[..], &(data + vlen).to_be_bytes()].concat())].concat(),
                1 => [flagged(b"tfhd", 0x11, &[&[0, 0, 0, 2][..], &u64::from(at).to_be_bytes(), &glen.to_be_bytes()].concat()), flagged(b"trun", 0x001, &[&1u32.to_be_bytes()[..], &(data + vlen).to_be_bytes()].concat())].concat(),
                2 => [flagged(b"tfhd", 0x10, &[&[0, 0, 0, 2][..], &glen.to_be_bytes()].concat()), flagged(b"trun", 0, &1u32.to_be_bytes())].concat(),
                _ => [flagged(b"tfhd", 0x02_0000, &[0, 0, 0, 2]), flagged(b"trun", 0x001, &[&1u32.to_be_bytes()[..], &(data + vlen).to_be_bytes()].concat())].concat(),
            };
            bx(b"moof", &[full(b"mfhd", 0, &[0, 0, 0, 1]), bx(b"traf", &vtraf), bx(b"traf", &gtraf)].concat())
        };
        let data = moof(0).len() as u32 + 8;
        let file = [ftyp, moov, moof(data), bx(b"mdat", &[video, gps.clone()].concat())].concat();
        let (n, g) = (file.len(), file.len() - gps.len());
        (file, g..n)
    }

    /// HOL-SEC-305: a fragmented movie's GPS samples are zeroed in its `moof`
    /// runs however the fragment names their place, and nothing else changes.
    #[test]
    fn a_fragmented_movie_loses_its_gps_samples() {
        for mode in 0..4 {
            let (mp4, gps) = fragmented_mp4_with_gps(mode);
            let mut want = mp4.clone();
            want[gps].fill(0);
            assert_eq!(strip_for_send("mp4", mp4).unwrap(), want, "mode {mode}");
        }
        // A GPS run whose size nothing gives is refused.
        assert!(strip_for_send("mp4", fragmented_mp4_with_gps(4).0).is_err());
        // So is a run longer than its box, in any track of such a movie.
        let (mut mp4, _) = fragmented_mp4_with_gps(0);
        let t = mp4.windows(4).position(|w| w == b"trun").unwrap() + 4;
        mp4[t + 4..t + 8].copy_from_slice(&2u32.to_be_bytes());
        assert!(strip_for_send("mp4", mp4).is_err());
        // Without a timed-metadata track every byte stays, as in 0.14.
        let (mut plain, _) = fragmented_mp4_with_gps(0);
        let h = plain.windows(4).position(|w| w == b"meta").unwrap();
        plain[h..h + 4].copy_from_slice(b"vide");
        assert_eq!(strip_for_send("mp4", plain.clone()).unwrap(), plain);
    }

    /// A HEIC that also holds a movie whose user data names a place.
    fn heic_with_a_movie() -> (Vec<u8>, Vec<u8>) {
        let xyz = bx(b"\xA9xyz", &[&[0, LOCATION.len() as u8 + 1, 0x15, 0xC7][..], LOCATION, b"/"].concat());
        let moov = bx(b"moov", &[full(b"mvhd", 0, &[0; 96]), bx(b"udta", &xyz)].concat());
        ([heic_with_gps(), moov.clone()].concat(), moov)
    }

    /// HOL-SEC-307: a HEIF that also holds a movie has the movie walked as a
    /// video's is; its items are stripped as before.
    #[test]
    fn a_heif_with_a_movie_loses_the_movies_location() {
        let (heic, moov) = heic_with_a_movie();
        let mut freed = moov;
        let u = freed.windows(4).position(|w| w == b"udta").unwrap();
        freed[u..u + 4].copy_from_slice(b"free");
        freed[u + 4..].fill(0);
        let want = [strip_for_send("heic", heic_with_gps()).unwrap(), freed].concat();
        assert_eq!(strip_for_send("heic", heic).unwrap(), want);
    }

    /// A fragmented movie or a HEIF with a movie, received and sent on, leaves
    /// without its location.
    #[test]
    fn a_forwarded_fragment_or_sequence_loses_its_location() {
        let dir = crate::test_tmp::tempdir().expect("tmp");
        let mut camm = mp4_with_location();
        let h = nth(&camm, b"hdlr", 1) + 12;
        camm[h..h + 4].copy_from_slice(b"camm");
        for (name, bytes) in [("frag.mp4", fragmented_mp4_with_gps(2).0), ("seq.heic", heic_with_a_movie().0), ("camm.mp4", camm)] {
            let path = dir.path().join(name);
            std::fs::write(&path, bytes).expect("write");
            assert!(!holds(&read_for_send(&path).expect(name), LOCATION), "{name}");
        }
    }

    /// Where `kind` occurs the `n`th time (from 0).
    fn nth(d: &[u8], kind: &[u8], n: usize) -> usize {
        d.windows(kind.len()).enumerate().filter(|(_, w)| *w == kind).nth(n).expect("present").0
    }

    /// HOL-SEC-306: the other places a location is kept lose it, and only
    /// those bytes change: a `camm` track goes like a `meta` one, a `gps ` box
    /// in `moov` or at the top becomes padding, and Matroska Attachments and
    /// Chapters become Void (ported from the 0.16 walker's test).
    #[test]
    fn other_location_carriers_lose_the_location() {
        let freed = |b: &[u8]| [&b[..4], b"free", &vec![0; b.len() - 8]].concat();
        // Google's camera motion track (`camm` handler) carries GPS packets.
        let mut camm = mp4_with_location();
        let h = nth(&camm, b"hdlr", 1) + 12;
        assert_eq!(&camm[h..h + 4], b"meta");
        camm[h..h + 4].copy_from_slice(b"camm");
        assert_eq!(strip_for_send("mp4", camm).unwrap(), strip_for_send("mp4", mp4_with_location()).unwrap(), "camm track");
        // A Novatek dashcam's `gps ` box in `moov`, and one at the top level.
        let gps = bx(b"gps ", LOCATION);
        let mvhd = full(b"mvhd", 0, &[0u8; 96]);
        let in_moov = |g: &[u8]| [bx(b"ftyp", b"isom\0\0\0\0"), bx(b"moov", &[&mvhd[..], g].concat())].concat();
        assert_eq!(strip_for_send("mp4", in_moov(&gps)).unwrap(), in_moov(&freed(&gps)), "gps box in moov");
        let top = [mp4_with_location(), gps.clone()].concat();
        let want = [strip_for_send("mp4", mp4_with_location()).unwrap(), freed(&gps)].concat();
        assert_eq!(strip_for_send("mp4", top).unwrap(), want, "top-level gps box");
        let heic = [heic_with_gps(), gps.clone()].concat();
        let want = [strip_for_send("heic", heic_with_gps()).unwrap(), freed(&gps)].concat();
        assert_eq!(strip_for_send("heic", heic).unwrap(), want, "gps box beside a HEIF's items");
        // Matroska Attachments (a photo with its Exif) and Chapters (a named place).
        for id in [[0x19, 0x41, 0xA4, 0x69], [0x10, 0x43, 0xA7, 0x70]] {
            let mut webm = webm_with_location();
            webm.truncate(nth(&webm, &[0x12, 0x54, 0xC3, 0x67], 0));
            let el = ebml(&id, &ebml(&[0x61, 0xA7], &ebml(&[0x46, 0x5C], LOCATION)));
            let mut voided = el.clone();
            let n = voided.len();
            void(&mut voided, 0, n);
            let want = [strip_for_send("mkv", webm.clone()).unwrap(), voided].concat();
            assert_eq!(strip_for_send("mkv", [webm, el].concat()).unwrap(), want, "{id:02X?}");
        }
    }

    /// A file received from someone and sent on is read through the same
    /// strip, so each crafted file above is refused or cleaned in time.
    #[test]
    fn a_forwarded_crafted_file_is_refused_or_cleaned_in_time() {
        let dir = crate::test_tmp::tempdir().expect("tmp");
        let [gif, _] = gifs_with_a_kept_block_past_the_end();
        let cases = [
            ("got.gif", gif, false),
            ("got.avi", avi_nested(200_000), false),
            ("got.mp4", mp4_with_empty_chunk_runs(150_000, 150_000), true),
            ("got.heic", heic_with_empty_extents(50_000), true),
            ("got.webp", webp_with_many_exif_chunks(500_000), true),
            ("cut.gif", gif_with_location()[..13].to_vec(), false),
            ("shared.mp4", mp4_with_shared_chunk_offsets(1 << 16, 1 << 20), false),
            ("overlap.heic", heic_with_overlapping_exif_extents(1, 4096, 1 << 20, 1 << 20), false),
        ];
        for (name, bytes, sends) in cases {
            let path = dir.path().join(name);
            std::fs::write(&path, bytes).expect("write");
            let answer = within(20, move || read_for_send(&path).map(|_| ()));
            assert_eq!(answer, Some(if sends { Ok(()) } else { Err(REFUSED.to_string()) }), "{name}");
        }
    }

    /// Every honest file strips to the bytes 0.14 gave, and every damaged copy
    /// gets 0.14's answer, a 0.14 panic counting as a refusal, except where a
    /// rule added since refuses it: a GIF cut inside its header or colour table
    /// (HOL-SEC-304) and a sample table longer than its box (HOL-SEC-302). The
    /// digest was taken on 0.14.3's base 4232da60 with only those two rules
    /// added.
    #[test]
    fn strip_answers_as_0_14_did() {
        let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node/image_check_fixtures");
        let honest: Vec<(&str, Vec<u8>)> = vec![
            ("mp4", mp4_with_location()),
            ("mov", mp4_with_chunk_runs()),
            ("webm", webm_with_location()),
            ("avi", avi_with_location()),
            ("avi", avi_nested(3)),
            ("jpg", jpeg_with_gps(1)),
            ("jpg", jpeg_with_gps(6)),
            ("png", png_with_gps()),
            ("webp", webp_with_gps(1)),
            ("webp", webp_with_gps(8)),
            ("heic", heic_with_gps()),
            ("heic", heic_with_split_exif()),
            ("gif", gif_with_location()),
        ];
        let crafted: Vec<Vec<u8>> = (1..=8)
            .map(|k| std::fs::read(fixtures.join(format!("webp_panic_{k}.webp"))).expect("fixture"))
            .collect();
        let mut h = <sha2::Sha256 as sha2::Digest>::new();
        let mut answer = |ext: &str, data: &[u8]| {
            let out = std::panic::catch_unwind(|| strip_for_send(ext, data.to_vec()));
            let ok = matches!(out, Ok(Ok(_)));
            match out {
                Ok(Ok(b)) => {
                    sha2::Digest::update(&mut h, (b.len() as u64).to_le_bytes());
                    sha2::Digest::update(&mut h, &b);
                }
                _ => sha2::Digest::update(&mut h, b"refused"),
            }
            ok
        };
        for (ext, data) in &honest {
            assert!(answer(ext, data), "an honest {ext} strips");
        }
        for data in &crafted {
            answer("webp", data);
        }
        for (ext, data) in honest.iter().filter(|(ext, _)| ["mov", "mp4", "avi", "heic", "gif", "webm", "jpg", "webp"].contains(ext)) {
            for k in 0..data.len() {
                answer(ext, &data[..k]);
                for v in [0x00, 0x01, 0x7F, 0xFF, data[k] ^ 0x80] {
                    if v != data[k] {
                        let mut d = data.clone();
                        d[k] = v;
                        answer(ext, &d);
                    }
                }
            }
        }
        assert_eq!(hex::encode(sha2::Digest::finalize(h)), "2dbb1035d1ff01a117ff4263ad85dc82dab23d43526373513037d4cb0368b217");
    }

    /// A GPS track whose chunks hold two, none, one and no samples.
    fn mp4_with_chunk_runs() -> Vec<u8> {
        let ftyp = bx(b"ftyp", b"qt  \0\0\x02\0qt  ");
        let samples: [&[u8]; 3] = [b"GPS1+37", b"GPS2.7749", b"GPS3-122.4194"];
        let at = ftyp.len() as u32 + 8;
        let mdat = bx(b"mdat", &samples.concat());
        let len = |k: usize| samples[k].len() as u32;
        let run = |first: u32, n: u32| [first.to_be_bytes(), n.to_be_bytes(), 1u32.to_be_bytes()].concat();
        let stsc = full(b"stsc", 0, &[&4u32.to_be_bytes()[..], &run(1, 2), &run(2, 0), &run(3, 1), &run(4, 0)].concat());
        let sizes = [3u32, len(0), len(1), len(2)].iter().flat_map(|v| v.to_be_bytes()).collect::<Vec<_>>();
        let stsz = full(b"stsz", 0, &[&[0u8; 4][..], &sizes].concat());
        let offsets = [4, at, at, at + len(0) + len(1), at].iter().flat_map(|v| v.to_be_bytes()).collect::<Vec<_>>();
        let stco = full(b"stco", 0, &offsets);
        let stbl = bx(b"stbl", &[full(b"stsd", 0, &[0, 0, 0, 0]), stsc, stsz, stco].concat());
        let hdlr = full(b"hdlr", 0, &[&[0u8; 4][..], b"meta", &[0; 12]].concat());
        let trak = bx(b"trak", &bx(b"mdia", &[hdlr, bx(b"minf", &stbl)].concat()));
        let moov = bx(b"moov", &[full(b"mvhd", 0, &[0x11; 96]), trak].concat());
        [ftyp, mdat, moov].concat()
    }

    /// A HEIC whose Exif item sits in two extents past a base offset, located
    /// by a version 1 `iloc`.
    fn heic_with_split_exif() -> Vec<u8> {
        let ftyp = bx(b"ftyp", b"heic\0\0\0\0mif1heic");
        let exif = [&[0u8, 0, 0, 6][..], b"Exif\0\0", &exif_with_gps(6)].concat();
        let half = exif.len() / 2;
        let meta = |base: u32| {
            let infe = |id: u8, t: &[u8; 4]| full(b"infe", 2, &[&[0, id, 0, 0][..], t, b"\0"].concat());
            let iinf = full(b"iinf", 0, &[&[0, 2][..], &infe(1, b"hvc1"), &infe(2, b"Exif")].concat());
            let ext = |off: usize, len: usize| [(off as u32).to_be_bytes(), (len as u32).to_be_bytes()].concat();
            let item1 = [&[0, 1, 0, 0, 0, 0][..], &base.to_be_bytes(), &[0, 1], &ext(0, 4)].concat();
            let item2 = [&[0, 2, 0, 0, 0, 0][..], &base.to_be_bytes(), &[0, 2], &ext(4, half), &ext(4 + half, exif.len() - half)].concat();
            full(b"meta", 0, &[iinf, full(b"iloc", 1, &[&[0x44, 0x40, 0, 2][..], &item1, &item2].concat())].concat())
        };
        let head = ftyp.len() + meta(0).len() + 8;
        let mdat = bx(b"mdat", &[b"HEVC".as_slice(), &exif].concat());
        [ftyp, meta(head as u32), mdat].concat()
    }
}
