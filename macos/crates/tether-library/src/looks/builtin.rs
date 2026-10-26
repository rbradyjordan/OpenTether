//! Built-in looks and colour match (`Looks/BuiltInLooks.swift`).

use crate::looks::cube::{CubeLut, LookDescriptor, Rgb};
use crate::store::SessionStore;
use crate::Result;

/// A small recipe turned into a 3D LUT, so built-in looks render through the
/// same path as an imported `.cube`.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct LookRecipe {
    /// -1…1: cooler ↔ warmer.
    pub warmth: f32,
    /// -1…1: magenta ↔ green.
    pub tint: f32,
    /// -1…1: flatter ↔ punchier (S-curve).
    pub contrast: f32,
    /// -1…1: -1 is monochrome.
    pub saturation: f32,
    /// 0…1: lifted, matte blacks.
    pub fade: f32,
    /// Colour pushed into shadows / highlights (split toning), with strength.
    pub shadow_tone: Rgb,
    pub highlight_tone: Rgb,
}

const LUMA: Rgb = [0.2126, 0.7152, 0.0722];

fn luma(c: Rgb) -> f32 {
    LUMA[0] * c[0] + LUMA[1] * c[1] + LUMA[2] * c[2]
}

impl LookRecipe {
    /// Bake the recipe into a LUT (`.cube` order: red fastest).
    pub fn lut(&self, size: usize, title: &str) -> CubeLut {
        let mut table = Vec::with_capacity(size * size * size * 3);
        let step = 1.0 / (size as f32 - 1.0);
        for b in 0..size {
            for g in 0..size {
                for r in 0..size {
                    table.extend(self.apply([r as f32 * step, g as f32 * step, b as f32 * step]));
                }
            }
        }
        CubeLut::new(size, title, table).unwrap_or_else(|_| CubeLut::identity(size))
    }

    /// The recipe applied to one colour in 0…1.
    pub fn apply(&self, input: Rgb) -> Rgb {
        let mut c = input;
        // White balance.
        c[0] *= 1.0 + 0.10 * self.warmth;
        c[2] *= 1.0 - 0.10 * self.warmth;
        c[1] *= 1.0 - 0.06 * self.tint;
        // Contrast: a smooth S-curve that keeps black and white anchored.
        if self.contrast != 0.0 {
            let k = self.contrast;
            c = c.map(|x| curve(x, k));
        }
        // Saturation around Rec. 709 luma.
        let l = luma(c);
        let s = (1.0 + self.saturation).max(0.0);
        c = c.map(|x| l + (x - l) * s);
        // Split toning, weighted by brightness.
        let l = luma(c);
        for ((x, s), h) in c.iter_mut().zip(self.shadow_tone).zip(self.highlight_tone) {
            *x += s * (1.0 - l) * (1.0 - l);
            *x += h * l * l;
        }
        // Fade: lift blacks, soften whites a touch.
        if self.fade > 0.0 {
            c = c.map(|x| 0.10 * self.fade + x * (1.0 - 0.14 * self.fade));
        }
        c.map(|x| x.clamp(0.0, 1.0))
    }
}

fn curve(x: f32, k: f32) -> f32 {
    let s = x * x * (3.0 - 2.0 * x); // smoothstep: an S-curve
    if k > 0.0 {
        x + (s - x) * k * 1.6
    } else {
        x + (0.5 - x) * (-k) * 0.45
    }
}

/// One shipped look.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BuiltInLook {
    pub id: &'static str,
    pub name: &'static str,
    pub recipe: LookRecipe,
}

/// Looks that ship with the app and are generated locally: no downloads, no account.
pub struct BuiltInLooks;

const fn recipe(
    warmth: f32,
    tint: f32,
    contrast: f32,
    saturation: f32,
    fade: f32,
    shadow_tone: Rgb,
    highlight_tone: Rgb,
) -> LookRecipe {
    LookRecipe {
        warmth,
        tint,
        contrast,
        saturation,
        fade,
        shadow_tone,
        highlight_tone,
    }
}

const Z: Rgb = [0.0; 3];

impl BuiltInLooks {
    pub const FAMILY: &'static str = "Open Tether";

    pub const ALL: [BuiltInLook; 10] = [
        BuiltInLook {
            id: "ot.natural",
            name: "Natural",
            recipe: recipe(0.0, 0.0, 0.15, 0.05, 0.0, Z, Z),
        },
        BuiltInLook {
            id: "ot.portrait",
            name: "Warm Portrait",
            recipe: recipe(0.35, 0.0, 0.1, -0.08, 0.15, Z, Z),
        },
        BuiltInLook {
            id: "ot.studio",
            name: "Cool Studio",
            recipe: recipe(-0.3, 0.0, 0.25, -0.05, 0.0, Z, Z),
        },
        BuiltInLook {
            id: "ot.chrome",
            name: "Chrome",
            recipe: recipe(0.0, 0.0, 0.35, -0.3, 0.0, [-0.01, 0.0, 0.02], Z),
        },
        BuiltInLook {
            id: "ot.film",
            name: "Faded Film",
            recipe: recipe(0.15, 0.0, -0.2, -0.15, 0.6, [0.0, 0.02, 0.04], Z),
        },
        BuiltInLook {
            id: "ot.golden",
            name: "Golden Hour",
            recipe: recipe(0.6, -0.1, 0.15, 0.1, 0.0, Z, [0.05, 0.02, -0.03]),
        },
        BuiltInLook {
            id: "ot.tealorange",
            name: "Teal & Orange",
            recipe: recipe(
                0.0,
                0.0,
                0.25,
                0.05,
                0.0,
                [-0.05, 0.02, 0.06],
                [0.06, 0.02, -0.04],
            ),
        },
        BuiltInLook {
            id: "ot.matte",
            name: "Matte",
            recipe: recipe(0.0, 0.0, -0.15, -0.1, 0.8, Z, Z),
        },
        BuiltInLook {
            id: "ot.mono",
            name: "Mono",
            recipe: recipe(0.0, 0.0, 0.15, -1.0, 0.0, Z, Z),
        },
        BuiltInLook {
            id: "ot.mono.contrast",
            name: "Mono Contrast",
            recipe: recipe(0.0, 0.0, 0.55, -1.0, 0.0, Z, Z),
        },
    ];

    pub fn by_id(id: &str) -> Option<BuiltInLook> {
        Self::ALL.into_iter().find(|l| l.id == id)
    }

    /// Store the built-ins (descriptor + cube) so the look picker, resolver
    /// and exports treat them like any other look. Safe to call every launch.
    pub fn install(store: &SessionStore) -> Result<()> {
        for entry in Self::ALL {
            let cube = entry.recipe.lut(25, entry.name).serialized();
            let descriptor = LookDescriptor::new(
                entry.id,
                entry.name,
                Self::FAMILY,
                25,
                &format!("builtin:{}", entry.id),
            );
            store.save_look(&descriptor, Some(cube.as_bytes()))?;
        }
        Ok(())
    }
}

/// On-device colour match: moves the target's colour statistics (mean and
/// spread per channel, in a decorrelated colour space) onto the reference's
/// (Reinhard's transfer) and bakes that into a LUT.
pub struct ColorMatch;

impl ColorMatch {
    /// `reference` / `target`: RGB samples in 0…1 (a downsampled frame each).
    pub fn lut(
        reference: &[Rgb],
        target: &[Rgb],
        strength: f32,
        size: usize,
        title: &str,
    ) -> CubeLut {
        if reference.is_empty() || target.is_empty() {
            return CubeLut::identity(size);
        }
        let reference: Vec<Rgb> = reference.iter().map(|c| to_lab(*c)).collect();
        let target: Vec<Rgb> = target.iter().map(|c| to_lab(*c)).collect();
        let (ref_mean, ref_sd) = stats(&reference);
        let (tgt_mean, tgt_sd) = stats(&target);
        let k = strength.clamp(0.0, 1.0);
        let mut table = Vec::with_capacity(size * size * size * 3);
        let step = 1.0 / (size as f32 - 1.0);
        for b in 0..size {
            for g in 0..size {
                for r in 0..size {
                    let input = [r as f32 * step, g as f32 * step, b as f32 * step];
                    let lab = to_lab(input);
                    let mut moved = [0f32; 3];
                    for c in 0..3 {
                        moved[c] =
                            (lab[c] - tgt_mean[c]) / tgt_sd[c].max(1e-4) * ref_sd[c] + ref_mean[c];
                    }
                    let out = from_lab(moved).map(|x| x.clamp(0.0, 1.0));
                    for c in 0..3 {
                        table.push(input[c] + (out[c] - input[c]) * k);
                    }
                }
            }
        }
        CubeLut::new(size, title, table).unwrap_or_else(|_| CubeLut::identity(size))
    }
}

fn stats(v: &[Rgb]) -> (Rgb, Rgb) {
    let n = v.len() as f32;
    let mut mean = [0f32; 3];
    for x in v {
        for c in 0..3 {
            mean[c] += x[c];
        }
    }
    mean = mean.map(|m| m / n);
    let mut var = [0f32; 3];
    for x in v {
        for c in 0..3 {
            var[c] += (x[c] - mean[c]) * (x[c] - mean[c]);
        }
    }
    (mean, var.map(|s| (s / n).sqrt()))
}

// lαβ via LMS (Ruderman et al.), as in Reinhard 2001.
fn to_lab(c: Rgb) -> Rgb {
    let l = 0.3811 * c[0] + 0.5783 * c[1] + 0.0402 * c[2];
    let m = 0.1967 * c[0] + 0.7244 * c[1] + 0.0782 * c[2];
    let s = 0.0241 * c[0] + 0.1288 * c[1] + 0.8444 * c[2];
    let lg = |x: f32| (x.max(1e-4) as f64).log10() as f32;
    let (ll, mm, ss) = (lg(l), lg(m), lg(s));
    [
        (ll + mm + ss) / 3f32.sqrt(),
        (ll + mm - 2.0 * ss) / 6f32.sqrt(),
        (ll - mm) / 2f32.sqrt(),
    ]
}

fn from_lab(v: Rgb) -> Rgb {
    let a = v[0] / 3f32.sqrt();
    let b = v[1] / 6f32.sqrt();
    let c = v[2] / 2f32.sqrt();
    let p = |x: f32| 10f64.powf(x as f64) as f32;
    let (l, m, s) = (p(a + b + c), p(a + b - c), p(a - 2.0 * b));
    [
        4.4679 * l - 3.5873 * m + 0.1193 * s,
        -1.2186 * l + 2.3809 * m - 0.1624 * s,
        0.0497 * l - 0.2439 * m + 1.2045 * s,
    ]
}
