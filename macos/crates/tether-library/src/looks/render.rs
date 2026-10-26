//! CPU look rendering. iOS renders looks with Core Image's `CIColorCube`;
//! here the same LUT is applied per pixel to 8- or 16-bit RGB with the
//! `image` crate (trilinear like `CIColorCube`, or tetrahedral).

use image::{DynamicImage, ImageBuffer, Rgb, Rgba};

use crate::imaging;
use crate::looks::builtin::{ColorMatch, LookRecipe};
use crate::looks::cube::{CubeLut, Interpolation, LookRendering};
use crate::Result;

/// Applies a LUT to 8-bit RGB pixels in place.
pub fn apply_lut_rgb8(
    img: &mut ImageBuffer<Rgb<u8>, Vec<u8>>,
    lut: &CubeLut,
    interpolation: Interpolation,
) {
    for p in img.pixels_mut() {
        let v = lut.sample_with(
            [
                p[0] as f32 / 255.0,
                p[1] as f32 / 255.0,
                p[2] as f32 / 255.0,
            ],
            interpolation,
        );
        for c in 0..3 {
            p[c] = (v[c] * 255.0).round().clamp(0.0, 255.0) as u8;
        }
    }
}

/// Applies a LUT to 8-bit RGBA pixels in place (alpha untouched).
pub fn apply_lut_rgba8(
    img: &mut ImageBuffer<Rgba<u8>, Vec<u8>>,
    lut: &CubeLut,
    interpolation: Interpolation,
) {
    for p in img.pixels_mut() {
        let v = lut.sample_with(
            [
                p[0] as f32 / 255.0,
                p[1] as f32 / 255.0,
                p[2] as f32 / 255.0,
            ],
            interpolation,
        );
        for c in 0..3 {
            p[c] = (v[c] * 255.0).round().clamp(0.0, 255.0) as u8;
        }
    }
}

/// Applies a LUT to 16-bit RGB pixels in place.
pub fn apply_lut_rgb16(
    img: &mut ImageBuffer<Rgb<u16>, Vec<u16>>,
    lut: &CubeLut,
    interpolation: Interpolation,
) {
    const MAX: f32 = 65535.0;
    for p in img.pixels_mut() {
        let v = lut.sample_with(
            [p[0] as f32 / MAX, p[1] as f32 / MAX, p[2] as f32 / MAX],
            interpolation,
        );
        for c in 0..3 {
            p[c] = (v[c] * MAX).round().clamp(0.0, MAX) as u16;
        }
    }
}

/// Applies a built-in look's recipe directly (no LUT quantisation).
pub fn apply_recipe_rgb8(img: &mut ImageBuffer<Rgb<u8>, Vec<u8>>, recipe: &LookRecipe) {
    for p in img.pixels_mut() {
        let v = recipe.apply([
            p[0] as f32 / 255.0,
            p[1] as f32 / 255.0,
            p[2] as f32 / 255.0,
        ]);
        for c in 0..3 {
            p[c] = (v[c] * 255.0).round().clamp(0.0, 255.0) as u8;
        }
    }
}

pub fn apply_recipe_rgb16(img: &mut ImageBuffer<Rgb<u16>, Vec<u16>>, recipe: &LookRecipe) {
    const MAX: f32 = 65535.0;
    for p in img.pixels_mut() {
        let v = recipe.apply([p[0] as f32 / MAX, p[1] as f32 / MAX, p[2] as f32 / MAX]);
        for c in 0..3 {
            p[c] = (v[c] * MAX).round().clamp(0.0, MAX) as u16;
        }
    }
}

/// Applies a look at `strength` to any decoded image, keeping 16-bit
/// images 16-bit and everything else as 8-bit RGB(A).
pub fn apply_look(
    img: DynamicImage,
    lut: &CubeLut,
    strength: f64,
    interpolation: Interpolation,
) -> DynamicImage {
    if strength <= 0.0 {
        return img;
    }
    let blended;
    let lut = if strength < 1.0 {
        blended = lut.blended(strength as f32);
        &blended
    } else {
        lut
    };
    match img {
        DynamicImage::ImageRgb16(mut b) => {
            apply_lut_rgb16(&mut b, lut, interpolation);
            DynamicImage::ImageRgb16(b)
        }
        DynamicImage::ImageRgba16(_)
        | DynamicImage::ImageRgb32F(_)
        | DynamicImage::ImageRgba32F(_)
        | DynamicImage::ImageLuma16(_)
        | DynamicImage::ImageLumaA16(_) => {
            let mut b = img.to_rgb16();
            apply_lut_rgb16(&mut b, lut, interpolation);
            DynamicImage::ImageRgb16(b)
        }
        DynamicImage::ImageRgba8(mut b) => {
            apply_lut_rgba8(&mut b, lut, interpolation);
            DynamicImage::ImageRgba8(b)
        }
        other => {
            let mut b = other.to_rgb8();
            apply_lut_rgb8(&mut b, lut, interpolation);
            DynamicImage::ImageRgb8(b)
        }
    }
}

/// The CPU renderer behind the canvas and the export queue's look pass:
/// decode (RAW develops through Core Image on macOS), scale, apply the
/// look, encode JPEG at 0.92 like iOS.
#[derive(Debug, Clone, Copy, Default)]
pub struct CpuLookRenderer {
    pub interpolation: Interpolation,
}

impl CpuLookRenderer {
    /// Synchronous render; `filename` lets RAW take the RAW path.
    pub fn render_blocking(
        &self,
        image: &[u8],
        filename: Option<&str>,
        look: Option<&CubeLut>,
        strength: f64,
        max_pixel_size: Option<u32>,
    ) -> Result<DynamicImage> {
        let img = imaging::decode(image, filename, max_pixel_size)?;
        Ok(match look {
            Some(lut) => apply_look(img, lut, strength, self.interpolation),
            None => img,
        })
    }
}

#[async_trait::async_trait]
impl LookRendering for CpuLookRenderer {
    async fn render(
        &self,
        image: Vec<u8>,
        look: Option<CubeLut>,
        strength: f64,
        max_pixel_size: Option<u32>,
    ) -> Result<Vec<u8>> {
        let this = *self;
        tokio::task::spawn_blocking(move || {
            let img =
                this.render_blocking(&image, None, look.as_ref(), strength, max_pixel_size)?;
            imaging::encode_jpeg(&img, 0.92)
        })
        .await
        .map_err(|e| crate::Error::Decode(e.to_string()))?
    }
}

/// Colour match between two encoded frames: samples each at 64 × 64 and
/// bakes the transfer into a 25-point LUT, as the iOS colour-match sheet does.
pub fn color_match_frames(
    reference: &[u8],
    target: &[u8],
    strength: f32,
    title: &str,
) -> Result<CubeLut> {
    let r = imaging::color_samples(reference, None, 64)
        .ok_or_else(|| crate::Error::Decode("could not read the reference frame".into()))?;
    let t = imaging::color_samples(target, None, 64)
        .ok_or_else(|| crate::Error::Decode("could not read the target frame".into()))?;
    Ok(ColorMatch::lut(&r, &t, strength, 25, title))
}
