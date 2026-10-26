//! The EXIF fields the inspector shows and the manifest records
//! (`Interop/EXIF.swift`), read straight from a JPEG's APP1 Exif segment
//! (also works on the TIFF header of most RAW files, since
//! CR2/NEF/ARW/RW2/ORF/DNG start with a TIFF IFD).

use chrono::{DateTime, FixedOffset, Local, NaiveDate, NaiveDateTime, TimeZone, Utc};

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ExifSummary {
    pub make: Option<String>,
    pub model: Option<String>,
    pub lens: Option<String>,
    pub date_time_original: Option<DateTime<Utc>>,
    /// Seconds.
    pub exposure_time: Option<f64>,
    pub f_number: Option<f64>,
    pub iso: Option<i64>,
    /// Millimetres.
    pub focal_length: Option<f64>,
    /// EV.
    pub exposure_bias: Option<f64>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub orientation: Option<i64>,
    pub serial_number: Option<String>,
    pub artist: Option<String>,
    pub copyright: Option<String>,
}

/// Shared formatters for exposure values (`PropertyFormat` in Swift).
pub mod format {
    /// `ƒ/2.8`, `ƒ/8`; the value is the f-number × 100.
    pub fn aperture(hundredths: i64) -> String {
        let f = hundredths as f64 / 100.0;
        if f == f.round() {
            format!("ƒ/{f:.0}")
        } else {
            format!("ƒ/{f:.1}")
        }
    }

    /// `1/250`, `2"`, `0.5"`, `Bulb`.
    pub fn shutter(seconds: f64) -> String {
        if seconds <= 0.0 {
            return "Bulb".into();
        }
        if seconds >= 0.3 {
            return if seconds == seconds.round() {
                format!("{seconds:.0}\"")
            } else {
                format!("{seconds:.1}\"")
            };
        }
        format!("1/{}", (1.0 / seconds).round() as i64)
    }
}

impl ExifSummary {
    /// `1/8000  ƒ/1.8  ISO 100  +0.3 EV  85 mm`.
    pub fn exposure_line(&self) -> String {
        let mut parts = Vec::new();
        if let Some(t) = self.exposure_time {
            parts.push(format::shutter(t));
        }
        if let Some(f) = self.f_number {
            parts.push(format::aperture((f * 100.0).round() as i64));
        }
        if let Some(i) = self.iso {
            parts.push(format!("ISO {i}"));
        }
        if let Some(b) = self.exposure_bias.filter(|b| *b != 0.0) {
            parts.push(format!("{b:+.1} EV"));
        }
        if let Some(fl) = self.focal_length {
            parts.push(format!("{fl:.0} mm"));
        }
        parts.join("  ")
    }

    pub fn camera_line(&self) -> String {
        [self.make.as_deref(), self.model.as_deref()]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" ")
            .trim_matches([' ', '\t'])
            .to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ExifError {
    #[error("no EXIF data")]
    NoExif,
    #[error("malformed EXIF: {0}")]
    Malformed(String),
}

struct Reader<'a> {
    b: &'a [u8],
    base: usize,
    little: bool,
}

impl Reader<'_> {
    fn u16(&self, o: usize) -> Option<u16> {
        let i = self.base.checked_add(o)?;
        let s = self.b.get(i..i + 2)?;
        Some(if self.little {
            u16::from_le_bytes([s[0], s[1]])
        } else {
            u16::from_be_bytes([s[0], s[1]])
        })
    }

    fn u32(&self, o: usize) -> Option<u32> {
        let i = self.base.checked_add(o)?;
        let s = self.b.get(i..i + 4)?;
        let a = [s[0], s[1], s[2], s[3]];
        Some(if self.little {
            u32::from_le_bytes(a)
        } else {
            u32::from_be_bytes(a)
        })
    }

    fn string(&self, o: usize, n: usize) -> Option<String> {
        let i = self.base.checked_add(o)?;
        let mut s = self.b.get(i..i.checked_add(n)?)?;
        while let [rest @ .., 0] = s {
            s = rest;
        }
        Some(
            String::from_utf8_lossy(s)
                .trim_matches([' ', '\t'])
                .to_string(),
        )
    }

    fn rational(&self, o: usize, signed: bool) -> Option<f64> {
        let n = self.u32(o)?;
        let d = self.u32(o + 4)?;
        if d == 0 {
            return None;
        }
        Some(if signed {
            n as i32 as f64 / d as i32 as f64
        } else {
            n as f64 / d as f64
        })
    }
}

/// Find and parse the Exif block in a JPEG, or parse `data` as a bare
/// TIFF (RAW files) when it starts with a TIFF header.
pub fn read(data: &[u8]) -> Result<ExifSummary, ExifError> {
    if data.len() <= 8 {
        return Err(ExifError::Malformed("too short".into()));
    }
    if (data[0] == 0x49 && data[1] == 0x49) || (data[0] == 0x4D && data[1] == 0x4D) {
        return parse_tiff(data, 0);
    }
    if data[0] != 0xFF || data[1] != 0xD8 {
        return Err(ExifError::NoExif);
    }
    let mut i = 2;
    while i + 4 <= data.len() && data[i] == 0xFF {
        let marker = data[i + 1];
        if marker == 0xDA || marker == 0xD9 {
            break;
        }
        let len = (data[i + 2] as usize) << 8 | data[i + 3] as usize;
        if marker == 0xE1 && i + 10 <= data.len() && &data[i + 4..i + 8] == b"Exif" {
            return parse_tiff(data, i + 10);
        }
        i += 2 + len;
    }
    Err(ExifError::NoExif)
}

fn parse_tiff(bytes: &[u8], base: usize) -> Result<ExifSummary, ExifError> {
    if base + 8 > bytes.len() {
        return Err(ExifError::Malformed("tiff header".into()));
    }
    let little = match (bytes[base], bytes[base + 1]) {
        (0x49, 0x49) => true,
        (0x4D, 0x4D) => false,
        _ => return Err(ExifError::Malformed("byte order".into())),
    };
    let r = Reader {
        b: bytes,
        base,
        little,
    };
    let ifd0 = r
        .u32(4)
        .ok_or_else(|| ExifError::Malformed("ifd0".into()))?;
    let mut out = ExifSummary::default();
    let mut exif_ifd = None;
    walk(&r, ifd0 as usize, &mut out, &mut exif_ifd, 0)?;
    if let Some(e) = exif_ifd {
        let mut none = None;
        walk(&r, e, &mut out, &mut none, 1)?;
    }
    Ok(out)
}

fn type_size(t: u16) -> usize {
    match t {
        3 => 2,
        4 | 9 => 4,
        5 | 10 => 8,
        _ => 1,
    }
}

fn walk(
    r: &Reader<'_>,
    ifd: usize,
    out: &mut ExifSummary,
    exif_ifd: &mut Option<usize>,
    depth: u8,
) -> Result<(), ExifError> {
    let count = r
        .u16(ifd)
        .filter(|c| *c < 1000)
        .ok_or_else(|| ExifError::Malformed("ifd count".into()))?;
    for i in 0..count as usize {
        let e = ifd + 2 + i * 12;
        let (Some(tag), Some(ty), Some(n)) = (r.u16(e), r.u16(e + 2), r.u32(e + 4)) else {
            break;
        };
        let size = type_size(ty).saturating_mul(n as usize);
        let vo = if size <= 4 {
            e + 8
        } else {
            r.u32(e + 8).unwrap_or(0) as usize
        };
        let s = || r.string(vo, n as usize);
        let short = || {
            if ty == 3 {
                r.u16(vo).map(i64::from)
            } else {
                r.u32(vo).map(i64::from)
            }
        };
        let rat = |signed| r.rational(vo, signed);
        match tag {
            0x010F => out.make = s(),
            0x0110 => out.model = s(),
            0x0112 => out.orientation = short(),
            0x013B => out.artist = s(),
            0x8298 => out.copyright = s(),
            0x8769 => {
                if depth == 0 {
                    *exif_ifd = Some(r.u32(e + 8).unwrap_or(0) as usize);
                }
            }
            0x829A => out.exposure_time = rat(false),
            0x829D => out.f_number = rat(false),
            0x8827 => out.iso = short(),
            0x9003 => out.date_time_original = s().and_then(|d| parse_date(&d)),
            0x9204 => out.exposure_bias = rat(true),
            0x920A => out.focal_length = rat(false),
            0xA002 => out.width = short(),
            0xA003 => out.height = short(),
            0xA434 => out.lens = s(),
            0xA431 => out.serial_number = s(),
            _ => {}
        }
    }
    Ok(())
}

/// Rewrites IFD0's Orientation tag inside a TIFF block (the payload of an
/// Exif APP1 after `Exif\0\0`). Returns false when there is none.
pub fn set_orientation(tiff: &mut [u8], value: u16) -> bool {
    if tiff.len() < 8 {
        return false;
    }
    let little = match (tiff[0], tiff[1]) {
        (0x49, 0x49) => true,
        (0x4D, 0x4D) => false,
        _ => return false,
    };
    let (ifd, count) = {
        let r = Reader {
            b: tiff,
            base: 0,
            little,
        };
        let Some(ifd) = r.u32(4).map(|v| v as usize) else {
            return false;
        };
        let Some(count) = r.u16(ifd) else {
            return false;
        };
        (ifd, count as usize)
    };
    for i in 0..count {
        let e = ifd + 2 + i * 12;
        if e + 12 > tiff.len() {
            return false;
        }
        let tag = if little {
            u16::from_le_bytes([tiff[e], tiff[e + 1]])
        } else {
            u16::from_be_bytes([tiff[e], tiff[e + 1]])
        };
        if tag == 0x0112 {
            let bytes = if little {
                value.to_le_bytes()
            } else {
                value.to_be_bytes()
            };
            tiff[e + 8] = bytes[0];
            tiff[e + 9] = bytes[1];
            return true;
        }
    }
    false
}

/// EXIF dates are "yyyy:MM:dd HH:mm:ss" in local time.
pub fn parse_date(s: &str) -> Option<DateTime<Utc>> {
    let naive = NaiveDateTime::parse_from_str(s.trim(), "%Y:%m:%d %H:%M:%S").ok()?;
    Local
        .from_local_datetime(&naive)
        .earliest()
        .map(|d| d.with_timezone(&Utc))
}

pub fn format_date(d: &DateTime<Utc>) -> String {
    d.with_timezone(&Local)
        .format("%Y:%m:%d %H:%M:%S")
        .to_string()
}

/// PTP DateTime strings: `YYYYMMDDThhmmss(.s)(Z|±hhmm)`; no zone means local time.
pub fn parse_ptp_datetime(s: &str) -> Option<DateTime<Utc>> {
    let c: Vec<char> = s.chars().collect();
    if c.len() < 15 || c[8] != 'T' {
        return None;
    }
    let num = |a: usize, b: usize| -> Option<u32> {
        c.get(a..b)?.iter().collect::<String>().parse().ok()
    };
    let (y, mo, d) = (num(0, 4)?, num(4, 6)?, num(6, 8)?);
    let (h, mi, se) = (num(9, 11)?, num(11, 13)?, num(13, 15)?);
    let naive = NaiveDate::from_ymd_opt(y as i32, mo, d)?.and_hms_opt(h, mi, se)?;
    let mut idx = 15;
    if c.get(idx) == Some(&'.') {
        idx += 2;
    }
    match c.get(idx) {
        Some('Z') => Some(Utc.from_utc_datetime(&naive)),
        Some(sign @ ('+' | '-')) if idx + 4 < c.len() => {
            let hh = num(idx + 1, idx + 3)?;
            let mm = num(idx + 3, (idx + 5).min(c.len()))?;
            let secs = (hh * 3600 + mm * 60) as i32 * if *sign == '-' { -1 } else { 1 };
            let tz = FixedOffset::east_opt(secs)?;
            tz.from_local_datetime(&naive)
                .single()
                .map(|d| d.with_timezone(&Utc))
        }
        _ => Local
            .from_local_datetime(&naive)
            .earliest()
            .map(|d| d.with_timezone(&Utc)),
    }
}

/// Builds a minimal Exif APP1 segment (marker included) for tests and for
/// files that arrive without one.
pub fn minimal_jpeg_exif(
    make: &str,
    model: &str,
    date_time_original: DateTime<Utc>,
    exposure_time: f64,
    f_number: f64,
    iso: u16,
) -> Vec<u8> {
    let mut tiff: Vec<u8> = Vec::new();
    let w16 = |v: &mut Vec<u8>, x: u16| v.extend_from_slice(&x.to_le_bytes());
    let w32 = |v: &mut Vec<u8>, x: u32| v.extend_from_slice(&x.to_le_bytes());
    tiff.extend_from_slice(b"II");
    w16(&mut tiff, 42);
    w32(&mut tiff, 8);
    let date = format!("{}\0", format_date(&date_time_original));
    let make_z = format!("{make}\0");
    let model_z = format!("{model}\0");
    // IFD0: Make, Model, ExifIFD pointer. Values stored after both IFDs.
    let (ifd0_count, exif_count) = (3usize, 4usize);
    let ifd0 = 8usize;
    let exif_ifd = ifd0 + 2 + ifd0_count * 12 + 4;
    let mut data_off = exif_ifd + 2 + exif_count * 12 + 4;
    let mut blobs: Vec<u8> = Vec::new();
    let mut put = |blobs: &mut Vec<u8>, b: &[u8]| {
        let o = data_off as u32;
        blobs.extend_from_slice(b);
        data_off += b.len();
        o
    };
    w16(&mut tiff, ifd0_count as u16);
    let make_o = put(&mut blobs, make_z.as_bytes());
    let model_o = put(&mut blobs, model_z.as_bytes());
    for (tag, ty, n, v) in [
        (0x010Fu16, 2u16, make_z.len() as u32, make_o),
        (0x0110, 2, model_z.len() as u32, model_o),
        (0x8769, 4, 1, exif_ifd as u32),
    ] {
        w16(&mut tiff, tag);
        w16(&mut tiff, ty);
        w32(&mut tiff, n);
        w32(&mut tiff, v);
    }
    w32(&mut tiff, 0);
    w16(&mut tiff, exif_count as u16);
    let rat = |n: u32, d: u32| {
        let mut b = n.to_le_bytes().to_vec();
        b.extend_from_slice(&d.to_le_bytes());
        b
    };
    let exp_o = put(
        &mut blobs,
        &rat((exposure_time * 1_000_000.0).round() as u32, 1_000_000),
    );
    let f_o = put(&mut blobs, &rat((f_number * 100.0).round() as u32, 100));
    let date_o = put(&mut blobs, date.as_bytes());
    for (tag, ty, v) in [(0x829Au16, 5u16, exp_o), (0x829D, 5, f_o)] {
        w16(&mut tiff, tag);
        w16(&mut tiff, ty);
        w32(&mut tiff, 1);
        w32(&mut tiff, v);
    }
    w16(&mut tiff, 0x8827);
    w16(&mut tiff, 3);
    w32(&mut tiff, 1);
    w16(&mut tiff, iso);
    w16(&mut tiff, 0);
    w16(&mut tiff, 0x9003);
    w16(&mut tiff, 2);
    w32(&mut tiff, date.len() as u32);
    w32(&mut tiff, date_o);
    w32(&mut tiff, 0);
    tiff.extend(blobs);
    let mut payload = b"Exif\0\0".to_vec();
    payload.extend(tiff);
    let len = (payload.len() + 2) as u16;
    let mut seg = vec![0xFF, 0xE1];
    seg.extend_from_slice(&len.to_be_bytes());
    seg.extend(payload);
    seg
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_what_it_writes() {
        let when = parse_date("2026:10:16 09:41:00").unwrap();
        let mut jpeg = vec![0xFF, 0xD8];
        jpeg.extend(minimal_jpeg_exif(
            "SONY",
            "ILCE-7M4",
            when,
            1.0 / 8000.0,
            1.8,
            100,
        ));
        jpeg.extend([0xFF, 0xD9]);
        let e = read(&jpeg).unwrap();
        assert_eq!(e.camera_line(), "SONY ILCE-7M4");
        assert_eq!(e.exposure_line(), "1/8000  ƒ/1.8  ISO 100");
        assert_eq!(e.date_time_original, Some(when));
        assert!(read(&[0xFF, 0xD8, 0xFF, 0xD9]).is_err());
        assert_eq!(
            read(&[0xFF, 0xD8, 0xFF, 0xD9, 0, 0, 0, 0, 0]),
            Err(ExifError::NoExif)
        );
    }

    #[test]
    fn ptp_dates() {
        let d = parse_ptp_datetime("20261016T094100Z").unwrap();
        assert_eq!(d.to_rfc3339(), "2026-10-16T09:41:00+00:00");
        let d = parse_ptp_datetime("20261016T094100.0+0200").unwrap();
        assert_eq!(d.to_rfc3339(), "2026-10-16T07:41:00+00:00");
        assert!(parse_ptp_datetime("2026").is_none());
    }
}
