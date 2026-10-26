//! Decoding, resizing and encoding for previews, looks and exports.
//!
//! JPEG, PNG and TIFF decode on the CPU with the `image` crate (EXIF
//! orientation applied). RAW develops through Core Image on macOS
//! ([`core_image`]); elsewhere, or when that fails, the camera's largest
//! embedded JPEG preview stands in. HEIF decodes through Core Image only.

#[cfg(target_os = "macos")]
pub mod core_image;

use std::io::Cursor;

use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::metadata::Orientation;
use image::{DynamicImage, ImageBuffer, ImageDecoder, ImageReader, Rgb};

use crate::capture_item::MediaKind;
use crate::interop::exif;
use crate::{util, Error, Result};

/// Where a JPEG sits inside a larger file, and its size.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EmbeddedJpeg {
    pub start: usize,
    pub end: usize,
    pub width: u32,
    pub height: u32,
}

impl EmbeddedJpeg {
    pub fn bytes<'a>(&self, data: &'a [u8]) -> &'a [u8] {
        &data[self.start..self.end]
    }
}

fn be16(d: &[u8], i: usize) -> Option<usize> {
    Some(((*d.get(i)? as usize) << 8) | *d.get(i + 1)? as usize)
}

/// Walks a JPEG that starts at `start`: returns where it ends (after EOI)
/// and its frame size, or `None` if it isn't a well-formed JPEG.
pub fn jpeg_info(data: &[u8], start: usize) -> Option<EmbeddedJpeg> {
    if data.get(start..start + 3)? != [0xFF, 0xD8, 0xFF] {
        return None;
    }
    let (mut width, mut height) = (0u32, 0u32);
    let mut i = start + 2;
    loop {
        if *data.get(i)? != 0xFF {
            return None;
        }
        let mut m = *data.get(i + 1)?;
        while m == 0xFF {
            i += 1;
            m = *data.get(i + 1)?;
        }
        match m {
            0xD9 => {
                return Some(EmbeddedJpeg {
                    start,
                    end: i + 2,
                    width,
                    height,
                })
            }
            0xD8 => return None,
            0x01 | 0xD0..=0xD7 => {
                i += 2;
                continue;
            }
            _ => {}
        }
        let len = be16(data, i + 2)?;
        if len < 2 {
            return None;
        }
        let seg_end = i + 2 + len;
        if seg_end > data.len() {
            return None;
        }
        if matches!(m, 0xC0..=0xCF) && !matches!(m, 0xC4 | 0xC8 | 0xCC) && len >= 7 {
            height = be16(data, i + 5)? as u32;
            width = be16(data, i + 7)? as u32;
        }
        if m != 0xDA {
            i = seg_end;
            continue;
        }
        // Entropy-coded data: runs until a marker that isn't stuffing or a restart.
        let mut j = seg_end;
        loop {
            if j + 1 >= data.len() {
                return None;
            }
            if data[j] != 0xFF {
                j += 1;
                continue;
            }
            match data[j + 1] {
                0x00 | 0xD0..=0xD7 => j += 2,
                0xFF => j += 1,
                _ => break,
            }
        }
        i = j;
    }
}

/// The largest JPEG embedded in a file (a RAW's full-size preview).
pub fn embedded_jpeg(data: &[u8]) -> Option<EmbeddedJpeg> {
    let mut best: Option<EmbeddedJpeg> = None;
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i] == 0xFF && data[i + 1] == 0xD8 && data[i + 2] == 0xFF {
            if let Some(j) = jpeg_info(data, i) {
                let area = u64::from(j.width) * u64::from(j.height);
                if area > 0 && best.is_none_or(|b| area > u64::from(b.width) * u64::from(b.height))
                {
                    best = Some(j);
                }
            }
        }
        i += 1;
    }
    best
}

/// Upright pixel size of any still the library handles, read without
/// decoding the pixels where possible.
pub fn dimensions(data: &[u8], filename: Option<&str>) -> Option<(u32, u32)> {
    let ext = filename.map(util::path_extension).unwrap_or("");
    let orientation = orientation_of(data);
    let upright = |(w, h): (u32, u32)| if orientation >= 5 { (h, w) } else { (w, h) };
    if MediaKind::from_extension(ext) == MediaKind::Raw {
        #[cfg(target_os = "macos")]
        if let Some(size) = core_image::extent(data, Some(ext), 1) {
            return Some(size);
        }
        if let Some(e) = exif::read(data)
            .ok()
            .filter(|e| e.width.is_some() && e.height.is_some())
        {
            return Some(upright((e.width? as u32, e.height? as u32)));
        }
        return embedded_jpeg(data).map(|e| upright((e.width, e.height)));
    }
    if let Ok(size) = ImageReader::new(Cursor::new(data))
        .with_guessed_format()
        .ok()?
        .into_dimensions()
    {
        return Some(upright(size));
    }
    #[cfg(target_os = "macos")]
    if let Some(size) = core_image::extent(data, None, orientation) {
        return Some(size);
    }
    None
}

/// The EXIF orientation (1…8) a file declares, 1 when unknown.
pub fn orientation_of(data: &[u8]) -> u8 {
    exif::read(data)
        .ok()
        .and_then(|e| e.orientation)
        .filter(|o| (1..=8).contains(o))
        .map(|o| o as u8)
        .unwrap_or(1)
}

pub fn orient(img: DynamicImage, orientation: u8) -> DynamicImage {
    let mut img = img;
    if let Some(o) = Orientation::from_exif(orientation) {
        img.apply_orientation(o);
    }
    img
}

/// Scales down so the long edge is at most `max` (never up).
pub fn fit(img: DynamicImage, max: Option<u32>) -> DynamicImage {
    match max {
        Some(m) if m > 0 && img.width().max(img.height()) > m => {
            img.resize(m, m, FilterType::Triangle)
        }
        _ => img,
    }
}

fn decode_with_image_crate(data: &[u8]) -> Result<DynamicImage> {
    let mut decoder = ImageReader::new(Cursor::new(data))
        .with_guessed_format()?
        .into_decoder()?;
    let orientation = decoder.orientation().unwrap_or(Orientation::NoTransforms);
    let mut img = DynamicImage::from_decoder(decoder)?;
    img.apply_orientation(orientation);
    Ok(img)
}

#[cfg(target_os = "macos")]
fn from_bitmap(b: core_image::Bitmap16) -> Option<DynamicImage> {
    let rgb: Vec<u16> = b
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|p| [p[0], p[1], p[2]])
        .collect();
    ImageBuffer::<Rgb<u16>, Vec<u16>>::from_raw(b.width, b.height, rgb)
        .map(DynamicImage::ImageRgb16)
}

/// The camera's embedded preview of a RAW, upright.
pub fn decode_embedded_preview(data: &[u8], max: Option<u32>) -> Result<DynamicImage> {
    let found = embedded_jpeg(data)
        .ok_or_else(|| Error::Decode("no embedded preview in this RAW file".into()))?;
    let jpeg = found.bytes(data);
    let mut decoder =
        ImageReader::with_format(Cursor::new(jpeg), image::ImageFormat::Jpeg).into_decoder()?;
    let own = decoder.orientation().unwrap_or(Orientation::NoTransforms);
    let img = DynamicImage::from_decoder(decoder)?;
    let raw_orientation = orientation_of(data);
    let img = if raw_orientation != 1 {
        orient(img, raw_orientation)
    } else {
        let mut img = img;
        img.apply_orientation(own);
        img
    };
    Ok(fit(img, max))
}

/// Decodes any still the library handles, upright, scaled to `max` long edge.
/// `filename` picks the RAW path by extension.
pub fn decode(data: &[u8], filename: Option<&str>, max: Option<u32>) -> Result<DynamicImage> {
    let ext = filename.map(util::path_extension).unwrap_or("");
    let kind = MediaKind::from_extension(ext);
    if kind == MediaKind::Raw {
        #[cfg(target_os = "macos")]
        if let Some(img) = develop_raw(data, ext, max) {
            return Ok(img);
        }
        return decode_embedded_preview(data, max);
    }
    match decode_with_image_crate(data) {
        Ok(img) => Ok(fit(img, max)),
        Err(e) => {
            #[cfg(target_os = "macos")]
            if let Some(img) =
                core_image::decode(data, None, orientation_of(data), max).and_then(from_bitmap)
            {
                return Ok(img);
            }
            // A RAW under an unknown name still has its preview.
            decode_embedded_preview(data, max).map_err(|_| e)
        }
    }
}

/// Full RAW development with the system RAW engine (macOS only).
#[cfg(target_os = "macos")]
pub fn develop_raw(data: &[u8], extension: &str, max: Option<u32>) -> Option<DynamicImage> {
    core_image::decode(data, Some(extension), 1, max).and_then(from_bitmap)
}

/// JPEG at `quality` (0…1, as ImageIO takes it).
pub fn encode_jpeg(img: &DynamicImage, quality: f64) -> Result<Vec<u8>> {
    let rgb = img.to_rgb8();
    let q = (quality.clamp(0.01, 1.0) * 100.0).round() as u8;
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, q.max(1)).encode_image(&rgb)?;
    Ok(out)
}

/// HEIF (macOS only; `None` elsewhere or on failure).
pub fn encode_heif(img: &DynamicImage, quality: f64) -> Option<Vec<u8>> {
    #[cfg(target_os = "macos")]
    {
        let rgb = img.to_rgb16();
        core_image::encode_heif(rgb.width(), rgb.height(), rgb.as_raw(), quality)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (img, quality);
        None
    }
}

/// Uncompressed 16-bit-per-channel TIFF (sRGB): the hand-off format for retouchers.
pub fn encode_tiff16(img: &DynamicImage) -> Result<Vec<u8>> {
    let rgb = img.to_rgb16();
    let mut out = Cursor::new(Vec::new());
    DynamicImage::ImageRgb16(rgb).write_to(&mut out, image::ImageFormat::Tiff)?;
    Ok(out.into_inner())
}

/// The Exif APP1 segment of a JPEG (marker included), if it has one.
pub fn exif_segment(jpeg: &[u8]) -> Option<Vec<u8>> {
    if jpeg.len() < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 {
        return None;
    }
    let mut i = 2;
    while i + 4 <= jpeg.len() && jpeg[i] == 0xFF {
        let marker = jpeg[i + 1];
        if marker == 0xDA || marker == 0xD9 {
            break;
        }
        let len = be16(jpeg, i + 2)?;
        let end = (i + 2 + len).min(jpeg.len());
        if marker == 0xE1 && jpeg.get(i + 4..i + 10) == Some(b"Exif\0\0") {
            return Some(jpeg[i..end].to_vec());
        }
        i = end;
    }
    None
}

/// Inserts an APP segment after SOI (and after a JFIF APP0, if any).
pub fn insert_segment(jpeg: &[u8], segment: &[u8]) -> Vec<u8> {
    let mut at = 2;
    if jpeg.len() > 6 && jpeg[2] == 0xFF && jpeg[3] == 0xE0 {
        if let Some(len) = be16(jpeg, 4) {
            at = (4 + len).min(jpeg.len());
        }
    }
    let mut out = Vec::with_capacity(jpeg.len() + segment.len());
    out.extend_from_slice(&jpeg[..at]);
    out.extend_from_slice(segment);
    out.extend_from_slice(&jpeg[at..]);
    out
}

/// Downsamples a frame to `side` × `side` at most and returns its pixels as
/// RGB in 0…1 (the colour match's input).
pub fn color_samples(data: &[u8], filename: Option<&str>, side: u32) -> Option<Vec<[f32; 3]>> {
    let img = decode(data, filename, Some(side.max(8) * 4)).ok()?;
    let small = img.thumbnail(side, side).to_rgb8();
    Some(
        small
            .pixels()
            .map(|p| {
                [
                    p[0] as f32 / 255.0,
                    p[1] as f32 / 255.0,
                    p[2] as f32 / 255.0,
                ]
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tiny_jpeg(w: u32, h: u32) -> Vec<u8> {
        let img = DynamicImage::ImageRgb8(ImageBuffer::from_pixel(w, h, Rgb([200u8, 100, 50])));
        encode_jpeg(&img, 0.9).unwrap()
    }

    #[test]
    fn finds_the_largest_embedded_preview() {
        let small = tiny_jpeg(16, 8);
        let big = tiny_jpeg(64, 48);
        let mut raw = b"II*\0junk-header".to_vec();
        raw.extend(&small);
        raw.extend([0u8, 1, 2, 0xFF, 0xD8, 3]);
        let start = raw.len();
        raw.extend(&big);
        raw.extend([9u8; 20]);
        let found = embedded_jpeg(&raw).unwrap();
        assert_eq!((found.width, found.height), (64, 48));
        assert_eq!(found.start, start);
        assert_eq!(found.bytes(&raw), &big[..]);
        let img = decode_embedded_preview(&raw, Some(32)).unwrap();
        assert_eq!(img.width(), 32);
    }

    #[test]
    fn decodes_and_fits() {
        let j = tiny_jpeg(100, 50);
        let img = decode(&j, Some("a.jpg"), Some(40)).unwrap();
        assert_eq!((img.width(), img.height()), (40, 20));
        let tiff = encode_tiff16(&img).unwrap();
        let back = decode(&tiff, Some("a.tif"), None).unwrap();
        assert_eq!(back.color(), image::ColorType::Rgb16);
    }
}
