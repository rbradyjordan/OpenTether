//! A shoot without a camera (`Tether/Connect/DemoSession.swift`): frames
//! "arrive" one by one as if someone were shooting, so rating, looks,
//! compare and export all work with nothing plugged in.
//!
//! The frames are drawn here (a sky, a sun and layered hills, a different
//! time of day per frame) so looks and colour matching have something to
//! show. `AppCore::start_demo` feeds them through an FTP-push session.

use image::codecs::jpeg::JpegEncoder;
use image::{Rgb, RgbImage};

pub const NAME: &str = "Demo shoot";
/// Marks demo sessions (shown as #demo in the session list).
pub const TAG: &str = "demo";
pub const FRAME_COUNT: usize = 8;
/// The iOS frame size.
pub const FRAME_SIZE: (u32, u32) = (2400, 1600);

/// `DEMO_0001.JPG`…
pub fn filename(index: usize) -> String {
    format!("DEMO_{:04}.JPG", index + 1)
}

fn hsb(h: f64, s: f64, b: f64) -> [f64; 3] {
    let h = (h.rem_euclid(1.0)) * 6.0;
    let i = h.floor();
    let f = h - i;
    let p = b * (1.0 - s);
    let q = b * (1.0 - s * f);
    let t = b * (1.0 - s * (1.0 - f));
    match i as i32 {
        0 => [b, t, p],
        1 => [q, b, p],
        2 => [p, b, t],
        3 => [p, q, b],
        4 => [t, p, b],
        _ => [b, p, q],
    }
}

fn to_px(c: [f64; 3]) -> Rgb<u8> {
    Rgb(c.map(|v| (v.clamp(0.0, 1.0) * 255.0).round() as u8))
}

fn blend(base: Rgb<u8>, top: [f64; 3], alpha: f64) -> Rgb<u8> {
    let b = base.0.map(|v| v as f64 / 255.0);
    to_px([
        b[0] + (top[0] - b[0]) * alpha,
        b[1] + (top[1] - b[1]) * alpha,
        b[2] + (top[2] - b[2]) * alpha,
    ])
}

/// Frame `index` of the demo as a JPEG (quality 0.88, like iOS).
pub fn frame(index: usize, width: u32, height: u32) -> Vec<u8> {
    let (w, h) = (width as f64, height as f64);
    let scale = w / FRAME_SIZE.0 as f64;
    let t = index as f64 / (FRAME_COUNT.max(2) - 1) as f64;
    let top = hsb(0.60 - 0.05 * t, 0.55, 0.95 - 0.35 * t);
    let horizon = hsb(0.08 - 0.03 * t, 0.35 + 0.45 * t, 1.0);
    let sun = hsb(0.11, 0.25 + 0.5 * t, 1.0);
    let sun_c = (w * (0.3 + 0.4 * t), h * (0.25 + 0.3 * t));
    let sun_r = 110.0 * scale;
    let mut img = RgbImage::new(width, height);
    // Sky: top colour to the horizon colour over 70 % of the height.
    for y in 0..height {
        let k = (y as f64 / (h * 0.7)).min(1.0);
        let c = [
            top[0] + (horizon[0] - top[0]) * k,
            top[1] + (horizon[1] - top[1]) * k,
            top[2] + (horizon[2] - top[2]) * k,
        ];
        let px = to_px(c);
        for x in 0..width {
            img.put_pixel(x, y, px);
        }
    }
    // Sun.
    let (x0, x1) = (
        (sun_c.0 - sun_r).max(0.0) as u32,
        ((sun_c.0 + sun_r).min(w - 1.0)).max(0.0) as u32,
    );
    let (y0, y1) = (
        (sun_c.1 - sun_r).max(0.0) as u32,
        ((sun_c.1 + sun_r).min(h - 1.0)).max(0.0) as u32,
    );
    for y in y0..=y1 {
        for x in x0..=x1 {
            let (dx, dy) = (x as f64 - sun_c.0, y as f64 - sun_c.1);
            if dx * dx + dy * dy <= sun_r * sun_r {
                let p = *img.get_pixel(x, y);
                img.put_pixel(x, y, blend(p, sun, 0.95));
            }
        }
    }
    // Three layers of hills, nearer ones darker.
    for layer in 0..3 {
        let lf = layer as f64;
        let base = h * (0.55 + 0.12 * lf);
        let shade = (0.45 - 0.13 * lf - 0.15 * t).max(0.08);
        let px = to_px(hsb(0.62 - 0.08 * lf, 0.35, shade));
        for x in 0..width {
            let xf = x as f64 / w;
            let wave =
                (xf * std::f64::consts::PI * (2.0 + lf) + index as f64 + lf).sin() * 90.0 * scale
                    + (xf * std::f64::consts::PI * 7.0 + lf).sin() * 25.0 * scale;
            let start = (base + wave).max(0.0) as u32;
            for y in start.min(height)..height {
                img.put_pixel(x, y, px);
            }
        }
    }
    let mut out = Vec::new();
    let _ = JpegEncoder::new_with_quality(&mut out, 88).encode_image(&img);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_are_jpegs_and_differ() {
        let a = frame(0, 240, 160);
        let b = frame(7, 240, 160);
        assert_eq!(&a[..2], &[0xFF, 0xD8]);
        assert_ne!(a, b);
        let img = image::load_from_memory(&a).unwrap();
        assert_eq!((img.width(), img.height()), (240, 160));
        assert_eq!(filename(0), "DEMO_0001.JPG");
    }
}
