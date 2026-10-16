//! 3D LUT math, the seven procedural catalog looks, and the Adobe `.cube`
//! writer/parser. Everything here is pure and deterministic.

use std::fmt::Write as _;

use sha2::{Digest, Sha256};

pub type Rgb = [f32; 3];

/// A cubic LUT. `data` is laid out with red varying fastest, then green,
/// then blue (the `.cube` order): index = r + size * (g + size * b).
#[derive(Debug, Clone, PartialEq)]
pub struct Lut3d {
    pub size: usize,
    pub data: Vec<Rgb>,
}

impl Lut3d {
    /// Builds a LUT by evaluating `f` at every grid node.
    pub fn from_fn(size: usize, mut f: impl FnMut(Rgb) -> Rgb) -> Self {
        assert!(size >= 2, "LUT size must be at least 2");
        let denom = (size - 1) as f32;
        let mut data = Vec::with_capacity(size * size * size);
        for b in 0..size {
            for g in 0..size {
                for r in 0..size {
                    let input = [r as f32 / denom, g as f32 / denom, b as f32 / denom];
                    data.push(clamp_rgb(f(input)));
                }
            }
        }
        Self { size, data }
    }

    pub fn identity(size: usize) -> Self {
        Self::from_fn(size, |c| c)
    }

    pub fn node(&self, r: usize, g: usize, b: usize) -> Rgb {
        self.data[r + self.size * (g + self.size * b)]
    }

    /// Serialises to Adobe `.cube` text with six decimals per component.
    pub fn to_cube(&self, title: &str) -> String {
        let mut out = String::with_capacity(self.data.len() * 30 + 128);
        let _ = writeln!(out, "TITLE \"{}\"", title.replace('"', "'"));
        let _ = writeln!(out, "LUT_3D_SIZE {}", self.size);
        out.push_str("DOMAIN_MIN 0 0 0\n");
        out.push_str("DOMAIN_MAX 1 1 1\n");
        for c in &self.data {
            let _ = writeln!(out, "{:.6} {:.6} {:.6}", c[0], c[1], c[2]);
        }
        out
    }

    /// Parses `.cube` text (the subset this service writes, plus comments and
    /// 1D tables being rejected explicitly).
    pub fn parse_cube(text: &str) -> Result<(String, Lut3d), CubeError> {
        let mut title = String::new();
        let mut size: Option<usize> = None;
        let mut data: Vec<Rgb> = Vec::new();
        for (lineno, raw) in text.lines().enumerate() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(rest) = line.strip_prefix("TITLE") {
                title = rest.trim().trim_matches('"').to_string();
            } else if let Some(rest) = line.strip_prefix("LUT_3D_SIZE") {
                let n: usize = rest
                    .trim()
                    .parse()
                    .map_err(|_| CubeError::Malformed(lineno + 1))?;
                if !(2..=256).contains(&n) {
                    return Err(CubeError::Malformed(lineno + 1));
                }
                size = Some(n);
                data.reserve(n * n * n);
            } else if line.starts_with("LUT_1D_SIZE") {
                return Err(CubeError::Unsupported("1D LUT"));
            } else if line.starts_with("DOMAIN_MIN") || line.starts_with("DOMAIN_MAX") {
                continue;
            } else {
                let mut it = line.split_whitespace().map(|t| t.parse::<f32>());
                let (Some(Ok(r)), Some(Ok(g)), Some(Ok(b)), None) =
                    (it.next(), it.next(), it.next(), it.next())
                else {
                    return Err(CubeError::Malformed(lineno + 1));
                };
                data.push([r, g, b]);
            }
        }
        let size = size.ok_or(CubeError::MissingSize)?;
        if data.len() != size * size * size {
            return Err(CubeError::WrongCount {
                expected: size * size * size,
                got: data.len(),
            });
        }
        Ok((title, Lut3d { size, data }))
    }

    pub fn sha256_hex_of(cube_text: &str) -> String {
        hex::encode(Sha256::digest(cube_text.as_bytes()))
    }
}

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum CubeError {
    #[error("malformed line {0}")]
    Malformed(usize),
    #[error("missing LUT_3D_SIZE")]
    MissingSize,
    #[error("expected {expected} entries, found {got}")]
    WrongCount { expected: usize, got: usize },
    #[error("unsupported: {0}")]
    Unsupported(&'static str),
}

// ---------------------------------------------------------------------------
// Colour helpers
// ---------------------------------------------------------------------------

pub fn clamp01(x: f32) -> f32 {
    if x.is_nan() {
        0.0
    } else {
        x.clamp(0.0, 1.0)
    }
}

pub fn clamp_rgb(c: Rgb) -> Rgb {
    [clamp01(c[0]), clamp01(c[1]), clamp01(c[2])]
}

/// Rec.709 luma.
pub fn luma(c: Rgb) -> f32 {
    0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
}

/// Scales chroma around luma; `amount` 1.0 = unchanged, 0.0 = greyscale.
pub fn saturate(c: Rgb, amount: f32) -> Rgb {
    let l = luma(c);
    [
        l + (c[0] - l) * amount,
        l + (c[1] - l) * amount,
        l + (c[2] - l) * amount,
    ]
}

pub fn smoothstep(x: f32) -> f32 {
    let x = clamp01(x);
    x * x * (3.0 - 2.0 * x)
}

/// Blends a channel toward its smoothstep (S-curve). `amount` 0 = identity.
pub fn s_curve(x: f32, amount: f32) -> f32 {
    x + amount * (smoothstep(x) - x)
}

pub fn map_channels(c: Rgb, f: impl Fn(f32) -> f32) -> Rgb {
    [f(c[0]), f(c[1]), f(c[2])]
}

fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

// ---------------------------------------------------------------------------
// Catalog looks
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Hint {
    pub warmth: f32,
    pub contrast: f32,
    pub saturation: f32,
}

#[derive(Debug, Clone, Copy)]
pub struct LookDef {
    pub id: &'static str,
    pub name: &'static str,
    pub family: &'static str,
    pub version: i64,
    pub hint: Hint,
    pub f: fn(Rgb) -> Rgb,
}

pub const CATALOG_SIZE: usize = 33;

pub const CATALOG: &[LookDef] = &[
    LookDef {
        id: "neutral",
        name: "Neutral",
        family: "neutral",
        version: 1,
        hint: Hint {
            warmth: 0.0,
            contrast: 0.0,
            saturation: 0.0,
        },
        f: look_neutral,
    },
    LookDef {
        id: "portrait-soft",
        name: "Portrait Soft",
        family: "portrait",
        version: 1,
        hint: Hint {
            warmth: 0.1,
            contrast: 0.15,
            saturation: -0.08,
        },
        f: look_portrait_soft,
    },
    LookDef {
        id: "film-warm",
        name: "Film Warm",
        family: "film",
        version: 1,
        hint: Hint {
            warmth: 0.35,
            contrast: -0.1,
            saturation: 0.0,
        },
        f: look_film_warm,
    },
    LookDef {
        id: "film-cool",
        name: "Film Cool",
        family: "film",
        version: 1,
        hint: Hint {
            warmth: -0.35,
            contrast: -0.1,
            saturation: 0.0,
        },
        f: look_film_cool,
    },
    LookDef {
        id: "mono-classic",
        name: "Mono Classic",
        family: "mono",
        version: 1,
        hint: Hint {
            warmth: 0.0,
            contrast: 0.2,
            saturation: -1.0,
        },
        f: look_mono_classic,
    },
    LookDef {
        id: "teal-orange",
        name: "Teal & Orange",
        family: "cinematic",
        version: 1,
        hint: Hint {
            warmth: 0.15,
            contrast: 0.1,
            saturation: 0.1,
        },
        f: look_teal_orange,
    },
    LookDef {
        id: "high-key",
        name: "High Key",
        family: "cinematic",
        version: 1,
        hint: Hint {
            warmth: 0.0,
            contrast: -0.3,
            saturation: -0.05,
        },
        f: look_high_key,
    },
];

pub fn catalog_lut(def: &LookDef) -> Lut3d {
    Lut3d::from_fn(CATALOG_SIZE, def.f)
}

/// Identity.
pub fn look_neutral(c: Rgb) -> Rgb {
    c
}

/// Gentle S-curve lift, -8% saturation, slight warmth.
pub fn look_portrait_soft(c: Rgb) -> Rgb {
    let c = map_channels(c, |x| s_curve(x, 0.25));
    let c = saturate(c, 0.92);
    clamp_rgb([c[0] + 0.012, c[1] + 0.002, c[2] - 0.012])
}

/// Warm shadows, lifted blacks, highlights rolling toward teal.
pub fn look_film_warm(c: Rgb) -> Rgb {
    let c = map_channels(c, |x| 0.035 + 0.965 * x); // lifted blacks
    let l = luma(c);
    let shadow = (1.0 - l).powi(2);
    let highlight = l.powi(2);
    let soft_roll = |x: f32| 1.0 - (1.0 - x).powf(1.15); // compress highlights
    let c = map_channels(c, soft_roll);
    clamp_rgb([
        c[0] + 0.08 * shadow - 0.03 * highlight,
        c[1] + 0.02 * shadow + 0.01 * highlight,
        c[2] - 0.06 * shadow + 0.03 * highlight,
    ])
}

/// Mirror of `look_film_warm`: cool shadows, warm-ish highlight roll.
pub fn look_film_cool(c: Rgb) -> Rgb {
    let c = map_channels(c, |x| 0.035 + 0.965 * x);
    let l = luma(c);
    let shadow = (1.0 - l).powi(2);
    let highlight = l.powi(2);
    let soft_roll = |x: f32| 1.0 - (1.0 - x).powf(1.15);
    let c = map_channels(c, soft_roll);
    clamp_rgb([
        c[0] - 0.06 * shadow + 0.03 * highlight,
        c[1] + 0.01 * shadow + 0.01 * highlight,
        c[2] + 0.08 * shadow - 0.03 * highlight,
    ])
}

/// Luminance with red-filter weighting (darkens skies, lightens skin), mild contrast.
pub fn look_mono_classic(c: Rgb) -> Rgb {
    let y = 0.50 * c[0] + 0.38 * c[1] + 0.12 * c[2];
    let y = s_curve(y, 0.35);
    let y = clamp01(y);
    [y, y, y]
}

/// Shadows toward teal, highlights toward orange, +10% saturation.
pub fn look_teal_orange(c: Rgb) -> Rgb {
    let l = luma(c);
    let shadow = (1.0 - l).powi(2);
    let highlight = l.powi(2);
    let c = [
        c[0] - 0.06 * shadow + 0.07 * highlight,
        c[1] + 0.02 * shadow + 0.02 * highlight,
        c[2] + 0.07 * shadow - 0.07 * highlight,
    ];
    let c = map_channels(c, |x| s_curve(x, 0.15));
    clamp_rgb(saturate(c, 1.10))
}

/// Lifted midtones, reduced contrast.
pub fn look_high_key(c: Rgb) -> Rgb {
    let c = map_channels(c, |x| clamp01(x).powf(0.8));
    let c = map_channels(c, |x| lerp(x, 0.55, 0.18));
    clamp_rgb(saturate(c, 0.95))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_maps_exactly() {
        let lut = Lut3d::identity(17);
        for b in 0..17 {
            for g in 0..17 {
                for r in 0..17 {
                    let got = lut.node(r, g, b);
                    let want = [r as f32 / 16.0, g as f32 / 16.0, b as f32 / 16.0];
                    assert_eq!(got, want);
                }
            }
        }
        let def = CATALOG.iter().find(|d| d.id == "neutral").unwrap();
        assert_eq!(catalog_lut(def), Lut3d::identity(CATALOG_SIZE));
    }

    #[test]
    fn every_catalog_output_in_unit_range() {
        for def in CATALOG {
            let lut = catalog_lut(def);
            assert_eq!(lut.data.len(), CATALOG_SIZE.pow(3), "{}", def.id);
            for c in &lut.data {
                for &v in c {
                    assert!((0.0..=1.0).contains(&v), "{} produced {v}", def.id);
                    assert!(!v.is_nan());
                }
            }
        }
    }

    #[test]
    fn catalog_ids_unique_and_seven() {
        assert_eq!(CATALOG.len(), 7);
        let mut ids: Vec<_> = CATALOG.iter().map(|d| d.id).collect();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), 7);
    }

    #[test]
    fn mono_is_grey() {
        for c in &catalog_lut(CATALOG.iter().find(|d| d.id == "mono-classic").unwrap()).data {
            assert_eq!(c[0], c[1]);
            assert_eq!(c[1], c[2]);
        }
    }

    #[test]
    fn looks_are_monotone_in_luma() {
        // Brighter neutral input should never come out darker for the tonal looks.
        for def in CATALOG {
            let mut last = -1.0f32;
            for i in 0..=100 {
                let x = i as f32 / 100.0;
                let l = luma((def.f)([x, x, x]));
                assert!(l >= last - 1e-5, "{} not monotone at {x}", def.id);
                last = l;
            }
        }
    }

    #[test]
    fn cube_round_trip() {
        let def = CATALOG.iter().find(|d| d.id == "teal-orange").unwrap();
        let lut = catalog_lut(def);
        let text = lut.to_cube(def.name);
        assert!(text.starts_with(
            "TITLE \"Teal & Orange\"\nLUT_3D_SIZE 33\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        ));
        assert_eq!(text.lines().count(), 4 + 33 * 33 * 33);
        let (title, parsed) = Lut3d::parse_cube(&text).unwrap();
        assert_eq!(title, "Teal & Orange");
        assert_eq!(parsed.size, 33);
        for (a, b) in lut.data.iter().zip(&parsed.data) {
            for k in 0..3 {
                assert!((a[k] - b[k]).abs() < 1e-6);
            }
        }
    }

    #[test]
    fn cube_red_varies_fastest() {
        let text = Lut3d::identity(2).to_cube("t");
        let rows: Vec<&str> = text.lines().skip(4).collect();
        assert_eq!(rows[0], "0.000000 0.000000 0.000000");
        assert_eq!(rows[1], "1.000000 0.000000 0.000000");
        assert_eq!(rows[2], "0.000000 1.000000 0.000000");
        assert_eq!(rows[4], "0.000000 0.000000 1.000000");
    }

    #[test]
    fn cube_parse_errors() {
        assert_eq!(
            Lut3d::parse_cube("TITLE \"x\"\n0 0 0\n"),
            Err(CubeError::MissingSize)
        );
        assert!(matches!(
            Lut3d::parse_cube("LUT_3D_SIZE 2\n0 0 0\n"),
            Err(CubeError::WrongCount {
                expected: 8,
                got: 1
            })
        ));
        assert_eq!(
            Lut3d::parse_cube("LUT_3D_SIZE 2\nfoo bar\n"),
            Err(CubeError::Malformed(2))
        );
        assert_eq!(
            Lut3d::parse_cube("LUT_1D_SIZE 2\n"),
            Err(CubeError::Unsupported("1D LUT"))
        );
    }
}
