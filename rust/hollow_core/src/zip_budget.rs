//! Reading the entries of a zip someone else made under a byte budget: what an entry
//! really inflates to is counted, never the size its header claims.

use std::io::Read;

/// Why an entry was not read.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Unpack {
    /// The entry alone unpacks past its own cap.
    TooLarge,
    /// The zip as a whole unpacks past its budget.
    OverBudget,
    Unreadable(String),
}

/// What one zip may still unpack to, across all of its entries.
#[derive(Debug)]
pub(crate) struct UnpackBudget {
    left: u64,
}

impl UnpackBudget {
    pub(crate) fn new(total: u64) -> Self {
        Self { left: total }
    }

    #[cfg(test)]
    pub(crate) fn left(&self) -> u64 {
        self.left
    }

    /// One entry's bytes, at most `cap` of them. A refused entry still pays for what it
    /// inflated, so a list of refused entries cannot loop the inflater for free.
    pub(crate) fn read(&mut self, entry: impl Read, cap: u64) -> Result<Vec<u8>, Unpack> {
        let mut buf = Vec::new();
        let n = self.pump(entry, cap, &mut buf)?;
        debug_assert_eq!(n, buf.len() as u64);
        Ok(buf)
    }

    /// [`Self::read`] into nothing: how many bytes the entry unpacks to.
    pub(crate) fn measure(&mut self, entry: impl Read, cap: u64) -> Result<u64, Unpack> {
        self.pump(entry, cap, &mut std::io::sink())
    }

    fn pump(&mut self, entry: impl Read, cap: u64, out: &mut impl std::io::Write) -> Result<u64, Unpack> {
        let limit = cap.min(self.left).saturating_add(1);
        let n = std::io::copy(&mut entry.take(limit), out).map_err(|e| Unpack::Unreadable(e.to_string()))?;
        let over_budget = n > self.left;
        self.left = self.left.saturating_sub(n);
        if n > cap {
            return Err(Unpack::TooLarge);
        }
        if over_budget {
            return Err(Unpack::OverBudget);
        }
        Ok(n)
    }
}

/// Room one central-directory record may take: 46 fixed bytes plus a name, extra field
/// and comment far longer than any Hollow container writes.
const RECORD_ROOM: u64 = 46 + 466;

/// Why a zip's index is refused before anything parses it, `None` when it is one plain
/// central directory of at most `max_entries` records. The zip reader allocates a record
/// for every entry the index declares, so a small file listing millions of them costs
/// many times its size; this walks the index the reader will pick (the end record must
/// close the file, so no other end record can be read first) and counts it exactly.
pub(crate) fn index_refused(zip: &[u8], max_entries: u64) -> Option<&'static str> {
    const EOCD: u32 = 0x0605_4b50;
    const LOCATOR: u32 = 0x0706_4b50;
    const EOCD64: u32 = 0x0606_4b50;
    const RECORD: u32 = 0x0201_4b50;
    let n16 = |at: usize| zip.get(at..at + 2).map(|b| u64::from(u16::from_le_bytes([b[0], b[1]])));
    let n32 = |at: usize| zip.get(at..at + 4).map(|b| u64::from(u32::from_le_bytes([b[0], b[1], b[2], b[3]])));
    let n64 = |at: usize| zip.get(at..at + 8).map(|b| u64::from_le_bytes(b.try_into().unwrap_or_default()));
    let sig = |at: usize, want: u32| n32(at) == Some(u64::from(want));

    let Some(eocd) = zip.len().checked_sub(22).filter(|&at| sig(at, EOCD) && n16(at + 20) == Some(0)) else {
        return Some("the zip does not end in its index");
    };
    let (Some(on_disk), Some(total), Some(size), Some(start)) = (n16(eocd + 8), n16(eocd + 10), n32(eocd + 12), n32(eocd + 16)) else {
        return Some("the zip does not end in its index");
    };
    let (mut on_disk, mut total, mut size, mut start, mut end) = (on_disk, total, size, start, eocd as u64);
    if let Some(locator) = eocd.checked_sub(20).filter(|&at| sig(at, LOCATOR)) {
        let Some(at) = n64(locator + 8).and_then(|at| usize::try_from(at).ok()).filter(|&at| sig(at, EOCD64)) else {
            return Some("the zip's index is not where it says");
        };
        let (Some(d), Some(t), Some(z), Some(st)) = (n64(at + 24), n64(at + 32), n64(at + 40), n64(at + 48)) else {
            return Some("the zip's index is not where it says");
        };
        (on_disk, total, size, start, end) = (d, t, z, st, at as u64);
    }
    if on_disk != total || total > max_entries {
        return Some("the zip lists more entries than this kind of file holds");
    }
    if size > total.saturating_mul(RECORD_ROOM) || start.checked_add(size) != Some(end) {
        return Some("the zip's index is not the size its entries need");
    }
    let (mut at, end) = (start as usize, end as usize);
    for _ in 0..total {
        let room = (|| Some(46 + n16(at + 28)? + n16(at + 30)? + n16(at + 32)?))();
        match room {
            Some(room) if sig(at, RECORD) && at as u64 + room <= end as u64 => at += room as usize,
            _ => return Some("the zip's index is not the entries it lists"),
        }
    }
    (at != end).then_some("the zip's index is not the entries it lists")
}

/// A zip whose index lists `n` entries, every one pointing at a single stored `name`
/// holding `bytes`: nothing in it inflates, the index alone is the cost.
#[cfg(test)]
pub(crate) fn zip_listing(n: usize, name: &str, bytes: &[u8]) -> Vec<u8> {
    use std::io::Write;
    let mut one = std::io::Cursor::new(Vec::new());
    {
        let mut z = zip::ZipWriter::new(&mut one);
        let opts = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        z.start_file(name, opts).unwrap();
        z.write_all(bytes).unwrap();
        z.finish().unwrap();
    }
    let one = one.into_inner();
    let eocd = one.len() - 22;
    let cd_at = u32::from_le_bytes(one[eocd + 16..eocd + 20].try_into().unwrap()) as usize;
    let crc = u32::from_le_bytes(one[14..18].try_into().unwrap());
    let mut f = one[..cd_at].to_vec();
    let cd_start = f.len() as u64;
    let record = |f: &mut Vec<u8>, entry: &[u8]| {
        f.extend(0x0201_4b50u32.to_le_bytes());
        f.extend(20u16.to_le_bytes());
        f.extend(20u16.to_le_bytes());
        f.extend([0u8; 6]);
        f.extend(0u16.to_le_bytes());
        f.extend(crc.to_le_bytes());
        f.extend((bytes.len() as u32).to_le_bytes());
        f.extend((bytes.len() as u32).to_le_bytes());
        f.extend((entry.len() as u16).to_le_bytes());
        f.extend([0u8; 8]);
        f.extend(0u32.to_le_bytes());
        f.extend(0u32.to_le_bytes());
        f.extend(entry);
    };
    record(&mut f, name.as_bytes());
    for i in 1..n {
        record(&mut f, format!("{i:x}").as_bytes());
    }
    let cd_end = f.len() as u64;
    let cd_size = cd_end - cd_start;
    if n < 0xffff {
        f.extend(0x0605_4b50u32.to_le_bytes());
        f.extend([0u8; 4]);
        f.extend((n as u16).to_le_bytes());
        f.extend((n as u16).to_le_bytes());
        f.extend((cd_size as u32).to_le_bytes());
        f.extend((cd_start as u32).to_le_bytes());
        f.extend(0u16.to_le_bytes());
        return f;
    }
    f.extend(0x0606_4b50u32.to_le_bytes());
    f.extend(44u64.to_le_bytes());
    f.extend(45u16.to_le_bytes());
    f.extend(45u16.to_le_bytes());
    f.extend([0u8; 8]);
    f.extend((n as u64).to_le_bytes());
    f.extend((n as u64).to_le_bytes());
    f.extend(cd_size.to_le_bytes());
    f.extend(cd_start.to_le_bytes());
    f.extend(0x0706_4b50u32.to_le_bytes());
    f.extend(0u32.to_le_bytes());
    f.extend(cd_end.to_le_bytes());
    f.extend(1u32.to_le_bytes());
    f.extend(0x0605_4b50u32.to_le_bytes());
    f.extend([0u8; 4]);
    f.extend(0xffffu16.to_le_bytes());
    f.extend(0xffffu16.to_le_bytes());
    f.extend(0xffff_ffffu32.to_le_bytes());
    f.extend(0xffff_ffffu32.to_le_bytes());
    f.extend(0u16.to_le_bytes());
    f
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_entry_is_read_only_one_byte_past_its_cap() {
        let mut b = UnpackBudget::new(1 << 20);
        assert_eq!(b.read(&[7u8; 100][..], 100), Ok(vec![7u8; 100]));
        assert_eq!(b.left(), (1 << 20) - 100);
        assert_eq!(b.read(&[0u8; 4096][..], 100), Err(Unpack::TooLarge));
        assert_eq!(b.left(), (1 << 20) - 100 - 101, "a refused entry pays for what it inflated");
    }

    #[test]
    fn entries_together_stop_at_the_budget() {
        let mut b = UnpackBudget::new(250);
        assert_eq!(b.measure(&[0u8; 100][..], 1000), Ok(100));
        assert_eq!(b.measure(&[0u8; 100][..], 1000), Ok(100));
        assert_eq!(b.measure(&[0u8; 4096][..], 1000), Err(Unpack::OverBudget));
        assert_eq!(b.left(), 0);
        assert_eq!(b.measure(&[][..], 1000), Ok(0));
        assert_eq!(b.measure(&[0u8; 1][..], 1000), Err(Unpack::OverBudget));
    }

    #[test]
    fn an_index_is_counted_before_anything_parses_it() {
        use std::io::Write;
        assert_eq!(index_refused(&zip_listing(10, "a", b"x"), 10), None);
        assert!(index_refused(&zip_listing(11, "a", b"x"), 10).is_some(), "11 entries passed a bound of 10");
        assert!(index_refused(&zip_listing(70_000, "a", b"x"), 100).is_some(), "a ZIP64 index of 70k entries passed");
        assert_eq!(index_refused(&zip_listing(70_000, "a", b"x"), 70_000), None, "a real ZIP64 index was refused");
        // What our own writer makes.
        let mut out = std::io::Cursor::new(Vec::new());
        let mut z = zip::ZipWriter::new(&mut out);
        for name in ["manifest.json", "blobs/a.webp", "blobs/b.webp"] {
            z.start_file(name, zip::write::SimpleFileOptions::default()).unwrap();
            z.write_all(name.as_bytes()).unwrap();
        }
        z.finish().unwrap();
        let real = out.into_inner();
        assert_eq!(index_refused(&real, 3), None);
        assert!(index_refused(&real, 2).is_some());
        // A comment after the end record could hide another one: refused.
        let mut commented = real.clone();
        let at = commented.len() - 2;
        commented[at..].copy_from_slice(&4u16.to_le_bytes());
        commented.extend(b"note");
        assert!(index_refused(&commented, 3).is_some());
        // An end record claiming a comment the file does not hold: the zip reader skips it
        // for an earlier one this check never saw.
        let mut claims = real.clone();
        let at = claims.len() - 2;
        claims[at..].copy_from_slice(&4u16.to_le_bytes());
        assert!(index_refused(&claims, 3).is_some(), "an end record claiming a missing comment passed");
        // An index that claims fewer records than it holds, or a size it does not have.
        let mut short = real.clone();
        let eocd = short.len() - 22;
        short[eocd + 8..eocd + 12].copy_from_slice(&[2, 0, 2, 0]);
        assert!(index_refused(&short, 3).is_some(), "a 3-record index declaring 2 passed");
        let mut wide = real.clone();
        let size = u32::from_le_bytes(wide[eocd + 12..eocd + 16].try_into().unwrap()) + 3 * 512;
        wide[eocd + 12..eocd + 16].copy_from_slice(&size.to_le_bytes());
        assert!(index_refused(&wide, 3).is_some(), "an index wider than its records passed");
        let mut narrow = real.clone();
        let size = u32::from_le_bytes(narrow[eocd + 12..eocd + 16].try_into().unwrap()) - 1;
        narrow[eocd + 12..eocd + 16].copy_from_slice(&size.to_le_bytes());
        assert!(index_refused(&narrow, 3).is_some(), "an index whose size field misses a byte passed");
        assert!(index_refused(b"not a zip at all, just bytes", 3).is_some());
        // A record far longer than any Hollow container writes.
        assert!(index_refused(&zip_listing(1, &"a".repeat(600), b"x"), 3).is_some(), "a 646-byte record passed");
    }
}
