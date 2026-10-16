//! Free-tier watermark burned into stored JPEG exports.
//!
//! Limitation: the service depends on `image` alone (no `imageproc`, no font
//! rasteriser), so there is no "TETHER · FREE" text. Instead it draws a
//! semi-transparent two-colour diagonal tile pattern across the frame plus a
//! solid badge rectangle (dark with a light inner bar) in the bottom-right
//! corner. Swap in a text renderer here if the branding ever needs words.

use image::{DynamicImage, Rgba, RgbaImage};
use std::io::Cursor;

#[derive(Debug, thiserror::Error)]
pub enum WatermarkError {
    #[error("decode: {0}")]
    Decode(#[from] image::ImageError),
}

const JPEG_QUALITY: u8 = 90;
/// Pattern period in pixels; scaled with the image so it reads the same on any size.
const TILE_BASE: u32 = 48;

/// Returns re-encoded JPEG bytes with the watermark applied.
pub fn watermark_jpeg(bytes: &[u8]) -> Result<Vec<u8>, WatermarkError> {
    let img = image::load_from_memory(bytes)?.to_rgba8();
    let marked = apply(img);
    let mut out = Cursor::new(Vec::with_capacity(bytes.len()));
    let rgb = DynamicImage::ImageRgba8(marked).to_rgb8();
    let enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, JPEG_QUALITY);
    rgb.write_with_encoder(enc)?;
    Ok(out.into_inner())
}

/// The drawing itself, separated so tests can inspect pixels.
pub fn apply(mut img: RgbaImage) -> RgbaImage {
    let (w, h) = img.dimensions();
    let scale = (w.max(h) / 1000).max(1);
    let tile = TILE_BASE * scale;
    let stripe = tile / 4;

    // 1. Tiled diagonal stripes: alternate light and dark, each blended at low alpha.
    for y in 0..h {
        for x in 0..w {
            let d = (x + y) % tile;
            if d < stripe {
                blend(img.get_pixel_mut(x, y), [255, 255, 255], 0.10);
            } else if d >= tile / 2 && d < tile / 2 + stripe {
                blend(img.get_pixel_mut(x, y), [0, 0, 0], 0.10);
            }
        }
    }

    // 2. Solid badge, bottom-right: dark plate with a light inner bar.
    let badge_w = (w / 6).clamp(48.min(w), w);
    let badge_h = (badge_w / 4).max(12.min(h));
    let margin = (w.min(h) / 40).max(4);
    let x0 = w.saturating_sub(badge_w + margin);
    let y0 = h.saturating_sub(badge_h + margin);
    for y in y0..h.min(y0 + badge_h) {
        for x in x0..w.min(x0 + badge_w) {
            *img.get_pixel_mut(x, y) = Rgba([20, 20, 24, 255]);
        }
    }
    let inset = (badge_h / 4).max(2);
    for y in (y0 + inset)..h.min(y0 + badge_h).saturating_sub(inset) {
        for x in (x0 + inset)..w.min(x0 + badge_w).saturating_sub(inset) {
            *img.get_pixel_mut(x, y) = Rgba([235, 235, 240, 255]);
        }
    }
    img
}

fn blend(p: &mut Rgba<u8>, rgb: [u8; 3], alpha: f32) {
    for (dst, &src) in p.0.iter_mut().zip(&rgb) {
        let v = *dst as f32 * (1.0 - alpha) + src as f32 * alpha;
        *dst = v.round().clamp(0.0, 255.0) as u8;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn badge_is_solid_and_pattern_changes_pixels() {
        let img = RgbaImage::from_pixel(400, 300, Rgba([128, 128, 128, 255]));
        let out = apply(img.clone());
        assert_eq!((out.width(), out.height()), (400, 300));
        // bottom-right badge plate is dark
        let p = out.get_pixel(400 - 8 - 1, 300 - 8 - 1);
        assert_eq!(p.0, [20, 20, 24, 255]);
        // some pixel somewhere differs from the flat grey (stripes)
        assert!(out.pixels().zip(img.pixels()).any(|(a, b)| a != b));
        // top-left region is only lightly touched (never fully opaque overlay)
        for y in 0..50 {
            for x in 0..50 {
                let v = out.get_pixel(x, y).0[0] as i32;
                assert!((v - 128).abs() <= 14, "stripe too strong: {v}");
            }
        }
    }

    #[test]
    fn jpeg_round_trip() {
        let img = DynamicImage::ImageRgb8(image::RgbImage::from_pixel(
            120,
            80,
            image::Rgb([200, 100, 50]),
        ));
        let mut buf = Cursor::new(Vec::new());
        img.write_to(&mut buf, image::ImageFormat::Jpeg).unwrap();
        let out = watermark_jpeg(&buf.into_inner()).unwrap();
        let decoded = image::load_from_memory(&out).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (120, 80));
    }

    #[test]
    fn tiny_image_does_not_panic() {
        let out = apply(RgbaImage::from_pixel(3, 2, Rgba([0, 0, 0, 255])));
        assert_eq!((out.width(), out.height()), (3, 2));
    }
}
