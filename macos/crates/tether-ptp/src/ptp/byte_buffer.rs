//! Little-endian byte reader/writer for PTP, PTP/IP and vendor payloads.

use thiserror::Error;

/// Little-endian byte reader/writer for PTP, PTP/IP and vendor payloads.
///
/// PTP wire format is little-endian throughout. Strings are a u8 count of
/// UTF-16 code units *including* the terminating NUL, followed by UTF-16LE
/// code units; an empty string is the single byte 0x00. Arrays are a u32
/// element count followed by the elements.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ByteBuffer {
    bytes: Vec<u8>,
    /// Read cursor.
    pub position: usize,
}

/// Reading past the end, or a string that cannot be decoded.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ReadError {
    #[error("out of bounds: needed {needed} bytes, {remaining} remaining")]
    OutOfBounds { needed: usize, remaining: usize },
    #[error("invalid string")]
    InvalidString,
}

pub type ReadResult<T> = Result<T, ReadError>;

impl ByteBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn from_bytes(bytes: impl Into<Vec<u8>>) -> Self {
        Self {
            bytes: bytes.into(),
            position: 0,
        }
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }

    pub fn len(&self) -> usize {
        self.bytes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }

    pub fn remaining(&self) -> usize {
        self.bytes.len().saturating_sub(self.position)
    }

    pub fn is_at_end(&self) -> bool {
        self.position >= self.bytes.len()
    }

    pub fn rewind(&mut self) {
        self.position = 0;
    }

    // MARK: Reading

    fn take(&mut self, n: usize) -> ReadResult<&[u8]> {
        let end = self
            .position
            .checked_add(n)
            .filter(|&e| e <= self.bytes.len())
            .ok_or(ReadError::OutOfBounds {
                needed: n,
                remaining: self.remaining(),
            })?;
        let start = self.position;
        self.position = end;
        Ok(&self.bytes[start..end])
    }

    fn take_array<const N: usize>(&mut self) -> ReadResult<[u8; N]> {
        let s = self.take(N)?;
        let mut out = [0u8; N];
        out.copy_from_slice(s);
        Ok(out)
    }

    pub fn read_u8(&mut self) -> ReadResult<u8> {
        Ok(self.take_array::<1>()?[0])
    }
    pub fn read_i8(&mut self) -> ReadResult<i8> {
        Ok(self.read_u8()? as i8)
    }
    pub fn read_u16(&mut self) -> ReadResult<u16> {
        Ok(u16::from_le_bytes(self.take_array()?))
    }
    pub fn read_i16(&mut self) -> ReadResult<i16> {
        Ok(i16::from_le_bytes(self.take_array()?))
    }
    pub fn read_u32(&mut self) -> ReadResult<u32> {
        Ok(u32::from_le_bytes(self.take_array()?))
    }
    pub fn read_i32(&mut self) -> ReadResult<i32> {
        Ok(i32::from_le_bytes(self.take_array()?))
    }
    pub fn read_u64(&mut self) -> ReadResult<u64> {
        Ok(u64::from_le_bytes(self.take_array()?))
    }
    pub fn read_i64(&mut self) -> ReadResult<i64> {
        Ok(i64::from_le_bytes(self.take_array()?))
    }

    /// 128-bit values are carried as (low, high) 64-bit halves.
    pub fn read_u128_halves(&mut self) -> ReadResult<(u64, u64)> {
        let low = self.read_u64()?;
        let high = self.read_u64()?;
        Ok((low, high))
    }

    pub fn read_bytes(&mut self, n: usize) -> ReadResult<Vec<u8>> {
        Ok(self.take(n)?.to_vec())
    }

    pub fn read_remaining(&mut self) -> Vec<u8> {
        let start = self.position.min(self.bytes.len());
        self.position = self.bytes.len();
        self.bytes[start..].to_vec()
    }

    pub fn skip(&mut self, n: usize) -> ReadResult<()> {
        self.take(n).map(|_| ())
    }

    /// PTP string: u8 count of UTF-16 units including NUL, then UTF-16LE.
    pub fn read_ptp_string(&mut self) -> ReadResult<String> {
        let units = self.read_u8()? as usize;
        if units == 0 {
            return Ok(String::new());
        }
        let mut code = Vec::with_capacity(units);
        for _ in 0..units {
            code.push(self.read_u16()?);
        }
        if code.last() == Some(&0) {
            code.pop();
        }
        // Some firmware omits the terminator or pads; tolerate both.
        if let Some(nul) = code.iter().position(|&u| u == 0) {
            code.truncate(nul);
        }
        Ok(String::from_utf16_lossy(&code))
    }

    /// A NUL-terminated UTF-16LE string with no length prefix (PTP/IP init packets).
    pub fn read_utf16le_z(&mut self) -> ReadResult<String> {
        let mut code = Vec::new();
        loop {
            let u = self.read_u16()?;
            if u == 0 {
                break;
            }
            code.push(u);
        }
        Ok(String::from_utf16_lossy(&code))
    }

    pub fn read_array<T>(
        &mut self,
        mut element: impl FnMut(&mut ByteBuffer) -> ReadResult<T>,
    ) -> ReadResult<Vec<T>> {
        let n = self.read_u32()? as usize;
        let mut out = Vec::with_capacity(n.min(1 << 16));
        for _ in 0..n {
            out.push(element(self)?);
        }
        Ok(out)
    }
    pub fn read_u16_array(&mut self) -> ReadResult<Vec<u16>> {
        self.read_array(|b| b.read_u16())
    }
    pub fn read_u32_array(&mut self) -> ReadResult<Vec<u32>> {
        self.read_array(|b| b.read_u32())
    }

    // MARK: Writing

    pub fn write_u8(&mut self, v: u8) {
        self.bytes.push(v);
    }
    pub fn write_i8(&mut self, v: i8) {
        self.bytes.push(v as u8);
    }
    pub fn write_u16(&mut self, v: u16) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn write_i16(&mut self, v: i16) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn write_u32(&mut self, v: u32) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn write_i32(&mut self, v: i32) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn write_u64(&mut self, v: u64) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn write_i64(&mut self, v: i64) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn write_bytes(&mut self, v: &[u8]) {
        self.bytes.extend_from_slice(v);
    }

    pub fn write_ptp_string(&mut self, s: &str) {
        if s.is_empty() {
            self.write_u8(0);
            return;
        }
        let units: Vec<u16> = s.encode_utf16().take(254).collect();
        self.write_u8(units.len() as u8 + 1);
        for u in units {
            self.write_u16(u);
        }
        self.write_u16(0);
    }

    pub fn write_utf16le_z(&mut self, s: &str) {
        for u in s.encode_utf16() {
            self.write_u16(u);
        }
        self.write_u16(0);
    }

    pub fn write_array<T: Copy>(&mut self, items: &[T], mut element: impl FnMut(&mut Self, T)) {
        self.write_u32(items.len() as u32);
        for &i in items {
            element(self, i);
        }
    }
    pub fn write_u16_array(&mut self, a: &[u16]) {
        self.write_array(a, |b, v| b.write_u16(v));
    }
    pub fn write_u32_array(&mut self, a: &[u32]) {
        self.write_array(a, |b, v| b.write_u32(v));
    }

    /// Overwrite a u32 at an absolute offset (used to back-patch lengths).
    /// Panics if the offset is out of range: this is a programming error on
    /// data we wrote ourselves, never wire data.
    pub fn patch_u32(&mut self, v: u32, offset: usize) {
        assert!(offset + 4 <= self.bytes.len(), "patch out of range");
        self.bytes[offset..offset + 4].copy_from_slice(&v.to_le_bytes());
    }

    /// Hex dump for logs: `01 02 0a ff`.
    pub fn hex_string(&self) -> String {
        self.bytes
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

impl From<Vec<u8>> for ByteBuffer {
    fn from(v: Vec<u8>) -> Self {
        Self::from_bytes(v)
    }
}

impl From<&[u8]> for ByteBuffer {
    fn from(v: &[u8]) -> Self {
        Self::from_bytes(v.to_vec())
    }
}

/// Compact hex for logs: `01020aff`.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scalar_round_trip() {
        let mut b = ByteBuffer::new();
        b.write_u8(0x12);
        b.write_u16(0x3456);
        b.write_u32(0x789A_BCDE);
        b.write_u64(0x0102_0304_0506_0708);
        b.write_i16(-2);
        b.write_i32(-3);
        assert_eq!(&b.bytes()[..3], &[0x12, 0x56, 0x34]);
        let mut r = ByteBuffer::from_bytes(b.bytes().to_vec());
        assert_eq!(r.read_u8().unwrap(), 0x12);
        assert_eq!(r.read_u16().unwrap(), 0x3456);
        assert_eq!(r.read_u32().unwrap(), 0x789A_BCDE);
        assert_eq!(r.read_u64().unwrap(), 0x0102_0304_0506_0708);
        assert_eq!(r.read_i16().unwrap(), -2);
        assert_eq!(r.read_i32().unwrap(), -3);
        assert!(r.is_at_end());
        assert!(r.read_u8().is_err());
    }

    #[test]
    fn ptp_string() {
        let mut b = ByteBuffer::new();
        b.write_ptp_string("Canon EOS R5");
        b.write_ptp_string("");
        assert_eq!(b.bytes()[0], 13); // 12 chars + NUL
        let mut r = ByteBuffer::from_bytes(b.bytes().to_vec());
        assert_eq!(r.read_ptp_string().unwrap(), "Canon EOS R5");
        assert_eq!(r.read_ptp_string().unwrap(), "");
    }

    #[test]
    fn ptp_string_without_terminator() {
        // Some firmware omits the NUL: count 2, two chars.
        let mut r = ByteBuffer::from_bytes(vec![2, 0x41, 0x00, 0x42, 0x00]);
        assert_eq!(r.read_ptp_string().unwrap(), "AB");
    }

    #[test]
    fn arrays() {
        let mut b = ByteBuffer::new();
        b.write_u16_array(&[0x1001, 0x1002]);
        b.write_u32_array(&[1, 2, 3]);
        let mut r = ByteBuffer::from_bytes(b.bytes().to_vec());
        assert_eq!(r.read_u16_array().unwrap(), vec![0x1001, 0x1002]);
        assert_eq!(r.read_u32_array().unwrap(), vec![1, 2, 3]);
    }

    #[test]
    fn truncated_array_is_an_error_not_a_panic() {
        let mut r = ByteBuffer::from_bytes(vec![0xFF, 0xFF, 0xFF, 0xFF, 1, 0]);
        assert!(r.read_u16_array().is_err());
        let mut r = ByteBuffer::from_bytes(vec![5, 0x41]);
        assert!(r.read_ptp_string().is_err());
    }
}
