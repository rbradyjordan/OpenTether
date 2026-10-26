//! `.cube` LUTs, look descriptors and the look resolver (`Looks/CubeLUT.swift`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::store::SessionStore;
use crate::Result;

/// An RGB triple in 0…1 (or any range for intermediate maths).
pub type Rgb = [f32; 3];

/// Rendering hints a look can carry (from the old look server).
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct LookHint {
    #[serde(default)]
    pub warmth: f64,
    #[serde(default)]
    pub contrast: f64,
    #[serde(default)]
    pub saturation: f64,
}

/// A look: built in, imported as a `.cube`, or made by colour match.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LookDescriptor {
    pub id: String,
    pub name: String,
    pub family: String,
    pub version: i64,
    pub size: i64,
    pub sha256: String,
    #[serde(rename = "cube_url")]
    pub cube_url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<LookHint>,
}

impl LookDescriptor {
    pub const NEUTRAL_ID: &'static str = "neutral";

    /// Version 1, size 33 by default (as Swift).
    pub fn new(id: &str, name: &str, family: &str, size: i64, cube_url: &str) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            family: family.into(),
            version: 1,
            size,
            sha256: String::new(),
            cube_url: cube_url.into(),
            hint: None,
        }
    }
}

/// Why a `.cube` was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CubeParseError {
    #[error("the .cube file has no LUT_3D_SIZE")]
    MissingSize,
    #[error("the .cube file has an unreadable line {0}")]
    BadLine(usize),
    #[error("the .cube file has {got} values, expected {expected}")]
    WrongCount { expected: usize, got: usize },
    #[error("unsupported LUT size {0}")]
    BadSize(usize),
}

/// How a LUT is sampled between its nodes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Interpolation {
    /// What Core Image's `CIColorCube` (and the Swift CPU path) does.
    #[default]
    Trilinear,
    /// Smoother along the grey axis; what Resolve and most graders use.
    Tetrahedral,
}

/// Adobe `.cube` 3D LUT: parse, serialise, sample.
#[derive(Debug, Clone, PartialEq)]
pub struct CubeLut {
    size: usize,
    title: String,
    /// RGB triples, red fastest: index = r + g·size + b·size².
    table: Vec<f32>,
    domain_min: Rgb,
    domain_max: Rgb,
}

impl CubeLut {
    pub fn new(size: usize, title: &str, table: Vec<f32>) -> Result<Self, CubeParseError> {
        Self::with_domain(size, title, table, [0.0; 3], [1.0; 3])
    }

    pub fn with_domain(
        size: usize,
        title: &str,
        table: Vec<f32>,
        domain_min: Rgb,
        domain_max: Rgb,
    ) -> Result<Self, CubeParseError> {
        if !(2..=65).contains(&size) {
            return Err(CubeParseError::BadSize(size));
        }
        let expected = size * size * size * 3;
        if table.len() != expected {
            return Err(CubeParseError::WrongCount {
                expected,
                got: table.len(),
            });
        }
        Ok(Self {
            size,
            title: title.to_string(),
            table,
            domain_min,
            domain_max,
        })
    }

    pub fn identity(size: usize) -> Self {
        let size = size.clamp(2, 65);
        let n = (size - 1) as f32;
        let mut t = Vec::with_capacity(size * size * size * 3);
        for b in 0..size {
            for g in 0..size {
                for r in 0..size {
                    t.extend([r as f32 / n, g as f32 / n, b as f32 / n]);
                }
            }
        }
        Self {
            size,
            title: "Identity".into(),
            table: t,
            domain_min: [0.0; 3],
            domain_max: [1.0; 3],
        }
    }

    pub fn size(&self) -> usize {
        self.size
    }

    pub fn title(&self) -> &str {
        &self.title
    }

    pub fn table(&self) -> &[f32] {
        &self.table
    }

    pub fn domain(&self) -> (Rgb, Rgb) {
        (self.domain_min, self.domain_max)
    }

    /// Parses `.cube` text (Resolve, Lightroom, Photoshop exports).
    pub fn parse(text: &str) -> Result<Self, CubeParseError> {
        let mut size: Option<usize> = None;
        let mut title = String::new();
        let (mut mn, mut mx) = ([0.0f32; 3], [1.0f32; 3]);
        let mut values: Vec<f32> = Vec::new();
        let lines = text.split(['\n', '\r']).filter(|l| !l.is_empty());
        for (i, raw) in lines.enumerate() {
            let line = raw.trim_matches([' ', '\t']);
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let upper = line.to_uppercase();
            if upper.starts_with("TITLE") {
                title = line[5..].trim_matches([' ', '"', '\t']).to_string();
                continue;
            }
            if upper.starts_with("LUT_3D_SIZE") {
                let n = line
                    .split(' ')
                    .next_back()
                    .and_then(|s| s.parse::<usize>().ok());
                size = Some(n.ok_or(CubeParseError::BadLine(i + 1))?);
                continue;
            }
            if upper.starts_with("LUT_1D_SIZE") {
                return Err(CubeParseError::BadLine(i + 1));
            }
            if upper.starts_with("DOMAIN_MIN") || upper.starts_with("DOMAIN_MAX") {
                let parts: Vec<f32> = line
                    .split(' ')
                    .skip(1)
                    .filter_map(|s| s.parse().ok())
                    .collect();
                if parts.len() != 3 {
                    return Err(CubeParseError::BadLine(i + 1));
                }
                let v = [parts[0], parts[1], parts[2]];
                if upper.starts_with("DOMAIN_MIN") {
                    mn = v;
                } else {
                    mx = v;
                }
                continue;
            }
            let parts: Vec<f32> = line
                .split([' ', '\t'])
                .filter(|s| !s.is_empty())
                .filter_map(|s| s.parse().ok())
                .collect();
            if parts.len() != 3 {
                return Err(CubeParseError::BadLine(i + 1));
            }
            values.extend(parts);
        }
        let n = size.ok_or(CubeParseError::MissingSize)?;
        Self::with_domain(n, &title, values, mn, mx)
    }

    /// `.cube` text with six decimals, the format Swift writes.
    pub fn serialized(&self) -> String {
        let f = |x: f32| format!("{x:.6}");
        let mut s = format!(
            "TITLE \"{}\"\nLUT_3D_SIZE {}\nDOMAIN_MIN {} {} {}\nDOMAIN_MAX {} {} {}\n",
            self.title,
            self.size,
            f(self.domain_min[0]),
            f(self.domain_min[1]),
            f(self.domain_min[2]),
            f(self.domain_max[0]),
            f(self.domain_max[1]),
            f(self.domain_max[2]),
        );
        s.reserve(self.table.len() * 9);
        for t in self.table.as_chunks::<3>().0 {
            s.push_str(&f(t[0]));
            s.push(' ');
            s.push_str(&f(t[1]));
            s.push(' ');
            s.push_str(&f(t[2]));
            s.push('\n');
        }
        s
    }

    #[inline(always)]
    fn node(&self, r: usize, g: usize, b: usize) -> Rgb {
        let i = (r + g * self.size + b * self.size * self.size) * 3;
        [self.table[i], self.table[i + 1], self.table[i + 2]]
    }

    #[inline(always)]
    fn position(&self, rgb: Rgb) -> ([usize; 3], [usize; 3], Rgb) {
        let n = (self.size - 1) as f32;
        let mut i0 = [0usize; 3];
        let mut i1 = [0usize; 3];
        let mut f = [0f32; 3];
        for c in 0..3 {
            let span = self.domain_max[c] - self.domain_min[c];
            let v = if span != 0.0 {
                (rgb[c] - self.domain_min[c]) / span
            } else {
                0.0
            };
            let p = if v.is_nan() { 0.0 } else { v.clamp(0.0, 1.0) } * n;
            i0[c] = p as usize;
            i1[c] = (i0[c] + 1).min(self.size - 1);
            f[c] = p - i0[c] as f32;
        }
        (i0, i1, f)
    }

    /// Trilinear lookup of one RGB value in 0…1.
    pub fn sample(&self, rgb: Rgb) -> Rgb {
        let (i0, i1, f) = self.position(rgb);
        let lerp = |a: Rgb, b: Rgb, t: f32| {
            [
                a[0] + (b[0] - a[0]) * t,
                a[1] + (b[1] - a[1]) * t,
                a[2] + (b[2] - a[2]) * t,
            ]
        };
        let c000 = self.node(i0[0], i0[1], i0[2]);
        let c100 = self.node(i1[0], i0[1], i0[2]);
        let c010 = self.node(i0[0], i1[1], i0[2]);
        let c110 = self.node(i1[0], i1[1], i0[2]);
        let c001 = self.node(i0[0], i0[1], i1[2]);
        let c101 = self.node(i1[0], i0[1], i1[2]);
        let c011 = self.node(i0[0], i1[1], i1[2]);
        let c111 = self.node(i1[0], i1[1], i1[2]);
        let c00 = lerp(c000, c100, f[0]);
        let c10 = lerp(c010, c110, f[0]);
        let c01 = lerp(c001, c101, f[0]);
        let c11 = lerp(c011, c111, f[0]);
        let c0 = lerp(c00, c10, f[1]);
        let c1 = lerp(c01, c11, f[1]);
        lerp(c0, c1, f[2])
    }

    /// Tetrahedral lookup: interpolates inside one of the six tetrahedra of
    /// the cell, so neutral input stays exactly on the grey axis of the LUT.
    pub fn sample_tetrahedral(&self, rgb: Rgb) -> Rgb {
        let (i0, i1, f) = self.position(rgb);
        let (fr, fg, fb) = (f[0], f[1], f[2]);
        let c000 = self.node(i0[0], i0[1], i0[2]);
        let c111 = self.node(i1[0], i1[1], i1[2]);
        let mix = |w: [f32; 4], a: Rgb, b: Rgb, c: Rgb, d: Rgb| {
            let mut o = [0f32; 3];
            for k in 0..3 {
                o[k] = w[0] * a[k] + w[1] * b[k] + w[2] * c[k] + w[3] * d[k];
            }
            o
        };
        if fr > fg {
            if fg > fb {
                let c100 = self.node(i1[0], i0[1], i0[2]);
                let c110 = self.node(i1[0], i1[1], i0[2]);
                mix([1.0 - fr, fr - fg, fg - fb, fb], c000, c100, c110, c111)
            } else if fr > fb {
                let c100 = self.node(i1[0], i0[1], i0[2]);
                let c101 = self.node(i1[0], i0[1], i1[2]);
                mix([1.0 - fr, fr - fb, fb - fg, fg], c000, c100, c101, c111)
            } else {
                let c001 = self.node(i0[0], i0[1], i1[2]);
                let c101 = self.node(i1[0], i0[1], i1[2]);
                mix([1.0 - fb, fb - fr, fr - fg, fg], c000, c001, c101, c111)
            }
        } else if fb > fg {
            let c001 = self.node(i0[0], i0[1], i1[2]);
            let c011 = self.node(i0[0], i1[1], i1[2]);
            mix([1.0 - fb, fb - fg, fg - fr, fr], c000, c001, c011, c111)
        } else if fb > fr {
            let c010 = self.node(i0[0], i1[1], i0[2]);
            let c011 = self.node(i0[0], i1[1], i1[2]);
            mix([1.0 - fg, fg - fb, fb - fr, fr], c000, c010, c011, c111)
        } else {
            let c010 = self.node(i0[0], i1[1], i0[2]);
            let c110 = self.node(i1[0], i1[1], i0[2]);
            mix([1.0 - fg, fg - fr, fr - fb, fb], c000, c010, c110, c111)
        }
    }

    pub fn sample_with(&self, rgb: Rgb, interpolation: Interpolation) -> Rgb {
        match interpolation {
            Interpolation::Trilinear => self.sample(rgb),
            Interpolation::Tetrahedral => self.sample_tetrahedral(rgb),
        }
    }

    /// Blend toward identity: strength 0 = no effect, 1 = full look.
    pub fn blended(&self, strength: f32) -> CubeLut {
        let s = strength.clamp(0.0, 1.0);
        if s >= 1.0 {
            return self.clone();
        }
        let id = CubeLut::identity(self.size);
        let table = self
            .table
            .iter()
            .zip(id.table.iter())
            .map(|(t, i)| i + (t - i) * s)
            .collect();
        CubeLut {
            table,
            ..self.clone()
        }
    }

    /// Apply to 8-bit RGBA pixels in place (CPU path for thumbnails/tests).
    pub fn apply_to_rgba8(&self, pixels: &mut [u8]) {
        for px in pixels.as_chunks_mut::<4>().0 {
            let v = self.sample([
                px[0] as f32 / 255.0,
                px[1] as f32 / 255.0,
                px[2] as f32 / 255.0,
            ]);
            for c in 0..3 {
                px[c] = (v[c] * 255.0).round().clamp(0.0, 255.0) as u8;
            }
        }
    }

    /// Core Image's `CIColorCube` layout: RGBA float32, red fastest.
    pub fn color_cube_data(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.size * self.size * self.size * 16);
        for t in self.table.as_chunks::<3>().0 {
            for v in [t[0], t[1], t[2], 1.0] {
                out.extend_from_slice(&v.to_ne_bytes());
            }
        }
        out
    }
}

/// A look applied to the canvas: which LUT, how strong. Carried forward to
/// each new capture.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LookStack {
    #[serde(rename = "lookID", default, skip_serializing_if = "Option::is_none")]
    pub look_id: Option<String>,
    pub strength: f64,
}

impl Default for LookStack {
    fn default() -> Self {
        Self {
            look_id: None,
            strength: 1.0,
        }
    }
}

impl LookStack {
    /// Strength is clamped to 0…1.
    pub fn new(look_id: Option<String>, strength: f64) -> Self {
        Self {
            look_id,
            strength: strength.clamp(0.0, 1.0),
        }
    }

    pub fn none() -> Self {
        Self::default()
    }

    pub fn is_neutral(&self) -> bool {
        self.look_id.is_none()
            || self.look_id.as_deref() == Some(LookDescriptor::NEUTRAL_ID)
            || self.strength == 0.0
    }
}

/// Fetches a look's cube bytes when the store doesn't have them.
#[async_trait::async_trait]
pub trait LookFetcher: Send + Sync {
    async fn fetch(&self, look: &LookDescriptor) -> Result<Vec<u8>>;
}

/// Resolves a [`LookStack`] to a [`CubeLut`] from the store (optionally
/// fetching a missing cube), memoising parsed LUTs.
pub struct LookResolver {
    store: Arc<SessionStore>,
    fetch: Option<Arc<dyn LookFetcher>>,
    memo: Mutex<HashMap<String, CubeLut>>,
}

impl LookResolver {
    pub fn new(store: Arc<SessionStore>, fetch: Option<Arc<dyn LookFetcher>>) -> Self {
        Self {
            store,
            fetch,
            memo: Mutex::new(HashMap::new()),
        }
    }

    /// `None` for a neutral stack or a look without a cube.
    pub async fn lut(&self, stack: &LookStack) -> Result<Option<CubeLut>> {
        let Some(id) = stack.look_id.as_deref().filter(|_| !stack.is_neutral()) else {
            return Ok(None);
        };
        if let Some(m) = self.memo.lock().unwrap_or_else(|e| e.into_inner()).get(id) {
            return Ok(Some(m.blended(stack.strength as f32)));
        }
        let mut data = self.store.cube(id)?;
        if data.is_none() {
            if let Some(fetch) = &self.fetch {
                if let Some(desc) = self.store.looks()?.into_iter().find(|l| l.id == id) {
                    let bytes = fetch.fetch(&desc).await?;
                    self.store.save_look(&desc, Some(&bytes))?;
                    data = Some(bytes);
                }
            }
        }
        let Some(d) = data else { return Ok(None) };
        let Ok(text) = String::from_utf8(d) else {
            return Ok(None);
        };
        let lut = CubeLut::parse(&text)?;
        self.memo
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id.to_string(), lut.clone());
        Ok(Some(lut.blended(stack.strength as f32)))
    }

    /// Forget memoised LUTs (after a look was edited or deleted).
    pub fn invalidate(&self) {
        self.memo.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }
}

/// Renders a capture with a look and returns a JPEG. The CPU
/// implementation is [`crate::looks::CpuLookRenderer`].
#[async_trait::async_trait]
pub trait LookRendering: Send + Sync {
    async fn render(
        &self,
        image: Vec<u8>,
        look: Option<CubeLut>,
        strength: f64,
        max_pixel_size: Option<u32>,
    ) -> Result<Vec<u8>>;
}
