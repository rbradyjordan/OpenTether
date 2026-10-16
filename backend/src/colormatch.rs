//! Deterministic colour matching: per-channel histogram (CDF) matching from a
//! target image onto a reference image, smoothed, blended with identity and
//! baked into a 3D LUT.

use image::{DynamicImage, GenericImageView, RgbImage};

use crate::looks::{clamp01, Lut3d, Rgb};

pub const MAX_EDGE: u32 = 256;
pub const SMOOTHING_WINDOW: usize = 5;

#[derive(Debug, Clone, PartialEq)]
pub struct MatchResult {
    pub lut: Lut3d,
    pub reference_mean: Rgb,
    pub target_mean: Rgb,
    pub matched_mean: Rgb,
}

#[derive(Debug, thiserror::Error)]
pub enum MatchError {
    #[error("could not decode {which} image: {source}")]
    Decode {
        which: &'static str,
        source: image::ImageError,
    },
    #[error("lut_size must be 17 or 33")]
    BadLutSize,
    #[error("strength must be within 0..=1")]
    BadStrength,
}

/// Decodes JPEG/PNG bytes, downscaled so the long edge is at most `MAX_EDGE`.
pub fn decode_small(bytes: &[u8], which: &'static str) -> Result<RgbImage, MatchError> {
    let img =
        image::load_from_memory(bytes).map_err(|source| MatchError::Decode { which, source })?;
    Ok(downscale(img))
}

pub fn downscale(img: DynamicImage) -> RgbImage {
    let (w, h) = img.dimensions();
    let long = w.max(h);
    if long > MAX_EDGE {
        let scale = MAX_EDGE as f64 / long as f64;
        let nw = ((w as f64 * scale).round() as u32).max(1);
        let nh = ((h as f64 * scale).round() as u32).max(1);
        img.thumbnail_exact(nw, nh).to_rgb8()
    } else {
        img.to_rgb8()
    }
}

/// 256-bin histogram per channel.
pub fn histograms(img: &RgbImage) -> [[u64; 256]; 3] {
    let mut h = [[0u64; 256]; 3];
    for p in img.pixels() {
        for c in 0..3 {
            h[c][p.0[c] as usize] += 1;
        }
    }
    h
}

/// Normalised CDF (last entry is 1.0 when the histogram is non-empty).
pub fn cdf(hist: &[u64; 256]) -> [f64; 256] {
    let total: u64 = hist.iter().sum();
    let mut out = [0f64; 256];
    if total == 0 {
        for (i, v) in out.iter_mut().enumerate() {
            *v = (i as f64 + 1.0) / 256.0;
        }
        return out;
    }
    let mut acc = 0u64;
    for (i, &n) in hist.iter().enumerate() {
        acc += n;
        out[i] = acc as f64 / total as f64;
    }
    out
}

/// For each target level `t`, the smallest reference level `r` with
/// `cdf_ref[r] >= cdf_target[t]`.
pub fn match_cdf(cdf_target: &[f64; 256], cdf_ref: &[f64; 256]) -> [u8; 256] {
    let mut map = [0u8; 256];
    let mut r = 0usize;
    for t in 0..256 {
        while r < 255 && cdf_ref[r] < cdf_target[t] - 1e-12 {
            r += 1;
        }
        map[t] = r as u8;
    }
    map
}

/// Moving average with `SMOOTHING_WINDOW`, clamped at the ends so the map stays
/// anchored; returns the mapping as 0..=1 floats.
pub fn smooth(map: &[u8; 256]) -> [f32; 256] {
    let half = SMOOTHING_WINDOW / 2;
    let mut out = [0f32; 256];
    for (i, slot) in out.iter_mut().enumerate() {
        let lo = i.saturating_sub(half);
        let hi = (i + half).min(255);
        let sum: u32 = map[lo..=hi].iter().map(|&v| v as u32).sum();
        *slot = sum as f32 / ((hi - lo + 1) as f32 * 255.0);
    }
    out
}

/// Blends a 0..=1 mapping with identity by `strength`.
pub fn blend_identity(map: &[f32; 256], strength: f32) -> [f32; 256] {
    let mut out = [0f32; 256];
    for (i, v) in out.iter_mut().enumerate() {
        let id = i as f32 / 255.0;
        *v = clamp01(id + (map[i] - id) * strength);
    }
    out
}

/// Evaluates a 256-entry curve at `x` in 0..=1 with linear interpolation.
pub fn eval_curve(curve: &[f32; 256], x: f32) -> f32 {
    let pos = clamp01(x) * 255.0;
    let i = pos.floor() as usize;
    let j = (i + 1).min(255);
    let t = pos - i as f32;
    curve[i] + (curve[j] - curve[i]) * t
}

pub fn mean_rgb(img: &RgbImage) -> Rgb {
    let n = (img.width() as u64 * img.height() as u64).max(1) as f64;
    let mut sum = [0f64; 3];
    for p in img.pixels() {
        for (acc, &v) in sum.iter_mut().zip(&p.0) {
            *acc += v as f64;
        }
    }
    [
        (sum[0] / n / 255.0) as f32,
        (sum[1] / n / 255.0) as f32,
        (sum[2] / n / 255.0) as f32,
    ]
}

/// The full pipeline on already-decoded small images.
pub fn color_match(
    reference: &RgbImage,
    target: &RgbImage,
    strength: f32,
    lut_size: usize,
) -> Result<MatchResult, MatchError> {
    if lut_size != 17 && lut_size != 33 {
        return Err(MatchError::BadLutSize);
    }
    if !(0.0..=1.0).contains(&strength) || strength.is_nan() {
        return Err(MatchError::BadStrength);
    }
    let h_ref = histograms(reference);
    let h_tgt = histograms(target);
    let mut curves: [[f32; 256]; 3] = [[0.0; 256]; 3];
    for c in 0..3 {
        let m = match_cdf(&cdf(&h_tgt[c]), &cdf(&h_ref[c]));
        curves[c] = blend_identity(&smooth(&m), strength);
    }
    let lut = Lut3d::from_fn(lut_size, |p| {
        [
            eval_curve(&curves[0], p[0]),
            eval_curve(&curves[1], p[1]),
            eval_curve(&curves[2], p[2]),
        ]
    });
    // Mean of the target after applying the curves pixel-wise.
    let n = (target.width() as u64 * target.height() as u64).max(1) as f64;
    let mut sum = [0f64; 3];
    for p in target.pixels() {
        for c in 0..3 {
            sum[c] += eval_curve(&curves[c], p.0[c] as f32 / 255.0) as f64;
        }
    }
    Ok(MatchResult {
        lut,
        reference_mean: mean_rgb(reference),
        target_mean: mean_rgb(target),
        matched_mean: [
            (sum[0] / n) as f32,
            (sum[1] / n) as f32,
            (sum[2] / n) as f32,
        ],
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgb as Px;

    fn flat(w: u32, h: u32, c: [u8; 3]) -> RgbImage {
        RgbImage::from_pixel(w, h, Px(c))
    }

    fn gradient(w: u32, h: u32, shift: i32) -> RgbImage {
        RgbImage::from_fn(w, h, |x, _| {
            let v = ((x as f32 / (w - 1) as f32) * 255.0) as i32 + shift;
            let v = v.clamp(0, 255) as u8;
            Px([v, v, v])
        })
    }

    #[test]
    fn matching_same_image_is_near_identity() {
        let img = gradient(256, 4, 0);
        let r = color_match(&img, &img, 1.0, 17).unwrap();
        for (i, c) in r.lut.data.iter().enumerate() {
            let rr = i % 17;
            let want = rr as f32 / 16.0;
            assert!((c[0] - want).abs() < 0.03, "node {i}: {} vs {want}", c[0]);
        }
    }

    #[test]
    fn strength_zero_is_exact_identity() {
        let a = flat(8, 8, [200, 30, 30]);
        let b = flat(8, 8, [20, 200, 90]);
        let r = color_match(&a, &b, 0.0, 17).unwrap();
        assert_eq!(r.lut, Lut3d::identity(17));
        assert_eq!(r.matched_mean, r.target_mean);
    }

    #[test]
    fn dark_target_moves_toward_bright_reference() {
        let reference = gradient(256, 8, 60);
        let target = gradient(256, 8, -60);
        let r = color_match(&reference, &target, 1.0, 33).unwrap();
        assert!(r.reference_mean[0] > r.target_mean[0]);
        assert!(r.matched_mean[0] > r.target_mean[0] + 0.1);
        assert!((r.matched_mean[0] - r.reference_mean[0]).abs() < 0.08);
        for c in &r.lut.data {
            for &v in c {
                assert!((0.0..=1.0).contains(&v));
            }
        }
    }

    #[test]
    fn deterministic() {
        let a = gradient(64, 8, 20);
        let b = gradient(64, 8, -20);
        assert_eq!(
            color_match(&a, &b, 0.7, 17).unwrap(),
            color_match(&a, &b, 0.7, 17).unwrap()
        );
    }

    #[test]
    fn rejects_bad_params() {
        let a = flat(2, 2, [0, 0, 0]);
        assert!(matches!(
            color_match(&a, &a, 1.0, 16),
            Err(MatchError::BadLutSize)
        ));
        assert!(matches!(
            color_match(&a, &a, 1.5, 17),
            Err(MatchError::BadStrength)
        ));
    }

    #[test]
    fn downscale_caps_long_edge() {
        let big = DynamicImage::ImageRgb8(flat(1024, 512, [1, 2, 3]));
        let small = downscale(big);
        assert_eq!((small.width(), small.height()), (256, 128));
        let tiny = downscale(DynamicImage::ImageRgb8(flat(10, 20, [0, 0, 0])));
        assert_eq!((tiny.width(), tiny.height()), (10, 20));
    }

    #[test]
    fn match_cdf_is_monotone() {
        let t = cdf(&histograms(&gradient(128, 2, 0))[0]);
        let r = cdf(&histograms(&gradient(128, 2, 40))[0]);
        let m = match_cdf(&t, &r);
        assert!(m.windows(2).all(|w| w[0] <= w[1]));
        assert!(m[0] >= 40);
    }
}
