//! Buffers that hold key material: wiped when dropped, and filled so that no buffer
//! is ever freed with a copy of a secret in it (HOL-SEC-200, HOL-SEC-201).

use std::io::{Read, Write};

use serde::Serialize;
use zeroize::{Zeroize, Zeroizing};

/// Bytes that hold key material, wiped when dropped.
pub(crate) type SecretBytes = Zeroizing<Vec<u8>>;

/// Wipe a buffer that held key material, its spare capacity too, before it is freed.
pub(crate) fn wipe(mut old: Vec<u8>) {
    old.zeroize();
    #[cfg(test)]
    counted::wiped(&old);
}

/// A growing buffer that wipes each buffer it outgrows, where a `Vec` would free it
/// as it is.
pub(crate) struct WipingWriter(SecretBytes);

impl WipingWriter {
    pub fn with_capacity(capacity: usize) -> Self {
        WipingWriter(Zeroizing::new(Vec::with_capacity(capacity)))
    }

    /// Room for `extra` more bytes, at least doubling when it must move.
    pub fn reserve(&mut self, extra: usize) {
        if self.0.capacity() - self.0.len() >= extra {
            return;
        }
        let mut bigger = Vec::with_capacity((self.0.len() + extra).max(self.0.capacity() * 2));
        bigger.extend_from_slice(&self.0);
        wipe(std::mem::replace(&mut *self.0, bigger));
    }

    pub fn push(&mut self, byte: u8) {
        self.reserve(1);
        self.0.push(byte);
    }

    pub fn into_inner(self) -> SecretBytes {
        self.0
    }

    /// The bytes in a buffer of exactly their length, for one that is kept.
    pub fn into_exact(self) -> SecretBytes {
        if self.0.capacity() == self.0.len() {
            self.0
        } else {
            Zeroizing::new(self.0.to_vec())
        }
    }
}

impl Write for WipingWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.reserve(buf.len());
        self.0.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Everything `reader` yields, starting from room for `hint` bytes.
pub(crate) fn read_to_end_wiped(mut reader: impl Read, hint: usize) -> std::io::Result<SecretBytes> {
    let mut out = WipingWriter::with_capacity(hint.max(64));
    loop {
        if out.0.len() == out.0.capacity() {
            out.reserve(out.0.capacity());
        }
        let (len, cap) = (out.0.len(), out.0.capacity());
        out.0.resize(cap, 0);
        let read = reader.read(&mut out.0[len..]);
        out.0.truncate(len + *read.as_ref().unwrap_or(&0));
        match read {
            Ok(0) => return Ok(out.into_inner()),
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
}

/// `value` as JSON, starting from room for `hint` bytes: one pass, for a row
/// rewritten often whose last size is the hint.
pub(crate) fn json_wiped<T: Serialize + ?Sized>(value: &T, hint: usize) -> Result<SecretBytes, serde_json::Error> {
    let mut out = WipingWriter::with_capacity(hint);
    serde_json::to_writer(&mut out, value)?;
    Ok(out.into_inner())
}

/// `value` as JSON in a buffer sized to it before the first byte is written.
pub(crate) fn sized_json<T: Serialize + ?Sized>(value: &T) -> Result<SecretBytes, String> {
    struct Count(usize);
    impl Write for Count {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0 += buf.len();
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    /// Refuses to grow past the capacity it was given.
    struct Fixed<'a>(&'a mut Vec<u8>);
    impl Write for Fixed<'_> {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            if self.0.capacity() - self.0.len() < buf.len() {
                return Err(std::io::Error::other("outgrew its buffer"));
            }
            self.0.extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut count = Count(0);
    serde_json::to_writer(&mut count, value).map_err(|e| e.to_string())?;
    let mut bytes = Zeroizing::new(Vec::with_capacity(count.0));
    serde_json::to_writer(Fixed(&mut bytes), value).map_err(|e| e.to_string())?;
    Ok(bytes)
}

/// Serde `deserialize_with` for a JSON byte array that holds a secret.
pub(crate) fn secret_bytes<'de, D: serde::Deserializer<'de>>(d: D) -> Result<SecretBytes, D::Error> {
    struct Bytes;
    impl<'de> serde::de::Visitor<'de> for Bytes {
        type Value = SecretBytes;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("a byte array")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(self, mut seq: A) -> Result<SecretBytes, A::Error> {
            let mut out = WipingWriter::with_capacity(seq.size_hint().unwrap_or(0).clamp(64, 4096));
            while let Some(byte) = seq.next_element::<u8>()? {
                out.push(byte);
            }
            Ok(out.into_inner())
        }
    }
    d.deserialize_seq(Bytes)
}

/// TEST-ONLY: the buffers this thread wiped, each checked empty, by address.
#[cfg(test)]
pub(crate) mod counted {
    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;

    thread_local! {
        static WIPED: Cell<usize> = const { Cell::new(0) };
        static AT: RefCell<VecDeque<usize>> = const { RefCell::new(VecDeque::new()) };
    }

    pub(super) fn wiped(old: &Vec<u8>) {
        assert!(old.is_empty(), "a buffer was freed with its bytes still in it");
        WIPED.with(|c| c.set(c.get() + 1));
        if old.capacity() > 0 {
            AT.with(|at| {
                let mut at = at.borrow_mut();
                at.push_back(old.as_ptr() as usize);
                if at.len() > 4096 {
                    at.pop_front();
                }
            });
        }
    }

    pub(crate) fn wipes() -> usize {
        WIPED.with(Cell::get)
    }

    /// Whether the buffer at `addr` was wiped since the log was last cleared.
    pub(crate) fn was_wiped(addr: *const u8) -> bool {
        AT.with(|at| at.borrow().contains(&(addr as usize)))
    }

    pub(crate) fn clear() {
        AT.with(|at| at.borrow_mut().clear());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_wiping_writer_wipes_every_buffer_it_outgrows() {
        let before = counted::wipes();
        let mut out = WipingWriter::with_capacity(4);
        out.write_all(&[7u8; 100]).unwrap();
        out.write_all(&[8u8; 300]).unwrap();
        assert!(counted::wipes() >= before + 2, "an outgrown buffer was freed unwiped");
        let bytes = out.into_exact();
        assert_eq!(bytes.capacity(), bytes.len());
        assert_eq!(&bytes[..100], &[7u8; 100][..]);
        assert_eq!(&bytes[100..], &[8u8; 300][..]);
    }

    #[test]
    fn reading_to_the_end_wipes_what_it_outgrows_and_keeps_every_byte() {
        let data: Vec<u8> = (0..10_000u32).map(|i| (i % 251) as u8).collect();
        let before = counted::wipes();
        let read = read_to_end_wiped(&data[..], 16).unwrap();
        assert_eq!(&read[..], &data[..]);
        assert!(counted::wipes() > before, "the buffer grew without a wipe");
        assert_eq!(&read_to_end_wiped(&b""[..], 0).unwrap()[..], b"");
    }

    #[test]
    fn json_is_written_whole_whichever_way_it_is_sized() {
        let value = serde_json::json!({ "secret": vec![200u8; 500], "name": "x" });
        let plain = serde_json::to_vec(&value).unwrap();
        let sized = sized_json(&value).unwrap();
        assert_eq!(&sized[..], &plain[..]);
        assert_eq!(sized.capacity(), sized.len(), "the sized buffer grew");
        assert_eq!(&json_wiped(&value, 8).unwrap()[..], &plain[..]);
    }

    #[test]
    fn a_secret_byte_array_reads_back_whole() {
        #[derive(serde::Deserialize)]
        struct Row {
            #[serde(deserialize_with = "secret_bytes")]
            private: SecretBytes,
        }
        let long: Vec<u8> = (0..300u32).map(|i| i as u8).collect();
        let before = counted::wipes();
        let json = format!("{{\"private\":{}}}", serde_json::to_string(&long).unwrap());
        let row: Row = serde_json::from_str(&json).unwrap();
        assert_eq!(&row.private[..], &long[..]);
        assert!(counted::wipes() > before, "a secret longer than the first buffer grew without a wipe");
        let short: Row = serde_json::from_slice(b"{\"private\":[1,2,3]}").unwrap();
        assert_eq!(&short.private[..], &[1, 2, 3]);
    }
}
