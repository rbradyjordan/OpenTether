//! `.cube` parsing, identity LUTs, blending, built-in looks, colour match,
//! the resolver and CPU rendering (Swift `CubeLUTTests`, `BuiltInLooksTests`).

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use image::{DynamicImage, ImageBuffer, Rgb};
use tether_library::looks::{
    apply_look, color_match_frames, BuiltInLooks, ColorMatch, CpuLookRenderer, CubeLut,
    CubeParseError, Interpolation, LookDescriptor, LookFetcher, LookRecipe, LookRendering,
    LookResolver, LookStack,
};
use tether_library::{imaging, SessionStore};

fn close(a: f32, b: f32) -> bool {
    (a - b).abs() < 1e-5
}

#[test]
fn identity_round_trip_and_sampling() {
    let id = CubeLut::identity(9);
    let text = id.serialized();
    assert!(text.contains("LUT_3D_SIZE 9"));
    let parsed = CubeLut::parse(&text).unwrap();
    assert_eq!(parsed.size(), 9);
    assert_eq!(parsed.title(), "Identity");
    for v in [0.0f32, 0.1, 0.37, 0.5, 0.99, 1.0] {
        for interp in [Interpolation::Trilinear, Interpolation::Tetrahedral] {
            let s = parsed.sample_with([v, v / 2.0, 1.0 - v], interp);
            assert!(
                close(s[0], v) && close(s[1], v / 2.0) && close(s[2], 1.0 - v),
                "{interp:?} {v} {s:?}"
            );
        }
    }
}

#[test]
fn parse_rejects_bad_input() {
    assert_eq!(
        CubeLut::parse("TITLE x\n0 0 0\n"),
        Err(CubeParseError::MissingSize)
    );
    assert!(matches!(
        CubeLut::parse("LUT_3D_SIZE 2\n0 0 0\n1 1 1\n"),
        Err(CubeParseError::WrongCount { .. })
    ));
    assert_eq!(
        CubeLut::parse(&("LUT_3D_SIZE 2\n0 0\n".to_string() + &"0 0 0\n".repeat(7))),
        Err(CubeParseError::BadLine(2))
    );
    assert!(CubeLut::parse("LUT_1D_SIZE 4\n").is_err());
    // Resolve-style header with comments, CRLF and a domain.
    let resolve = "# Created by Resolve\r\nTITLE \"Warm\"\r\nLUT_3D_SIZE 2\r\nDOMAIN_MIN 0 0 0\r\nDOMAIN_MAX 1 1 1\r\n\r\n0 0 0\r\n1 0 0\r\n0 1 0\r\n1 1 0\r\n0 0 1\r\n1 0 1\r\n0 1 1\r\n1 1 1\r\n";
    let lut = CubeLut::parse(resolve).unwrap();
    assert_eq!(lut.title(), "Warm");
    assert!(close(lut.sample([0.25, 0.5, 0.75])[1], 0.5));
}

#[test]
fn blend_and_apply() {
    // A LUT that inverts everything.
    let mut t = Vec::new();
    for b in 0..2 {
        for g in 0..2 {
            for r in 0..2 {
                t.extend([1.0 - r as f32, 1.0 - g as f32, 1.0 - b as f32]);
            }
        }
    }
    let inv = CubeLut::new(2, "Invert", t).unwrap();
    assert!(close(inv.sample([0.25, 0.5, 1.0])[0], 0.75));
    assert!(close(inv.sample_tetrahedral([0.25, 0.5, 1.0])[0], 0.75));
    let half = inv.blended(0.5);
    assert!(close(half.sample([0.0, 0.0, 0.0])[0], 0.5));
    let mut px = vec![0u8, 0, 0, 255, 255, 255, 255, 255];
    inv.apply_to_rgba8(&mut px);
    assert_eq!(px, [255, 255, 255, 255, 0, 0, 0, 255]);
    assert_eq!(inv.color_cube_data().len(), 8 * 4 * 4);

    // The CPU renderer on 8- and 16-bit images.
    let img = DynamicImage::ImageRgb8(ImageBuffer::from_pixel(4, 4, Rgb([10u8, 200, 30])));
    let out = apply_look(img, &inv, 1.0, Interpolation::Trilinear).to_rgb8();
    assert_eq!(out.get_pixel(0, 0).0, [245, 55, 225]);
    let img16 = DynamicImage::ImageRgb16(ImageBuffer::from_pixel(2, 2, Rgb([0u16, 65535, 32768])));
    let out16 = apply_look(img16, &inv, 1.0, Interpolation::Tetrahedral);
    assert_eq!(
        out16.as_rgb16().unwrap().get_pixel(1, 1).0,
        [65535, 0, 32767]
    );
    let id = CubeLut::identity(17);
    let img = DynamicImage::ImageRgb8(ImageBuffer::from_fn(16, 16, |x, y| {
        Rgb([(x * 16) as u8, (y * 16) as u8, 77])
    }));
    assert_eq!(
        apply_look(img.clone(), &id, 1.0, Interpolation::Tetrahedral),
        img,
        "identity LUT leaves pixels alone"
    );
}

#[test]
fn look_stack_neutral() {
    assert!(LookStack::default().is_neutral());
    assert!(LookStack::new(Some("neutral".into()), 1.0).is_neutral());
    assert!(LookStack::new(Some("film".into()), 0.0).is_neutral());
    assert!(!LookStack::new(Some("film".into()), 0.5).is_neutral());
    assert_eq!(LookStack::new(Some("x".into()), 7.0).strength, 1.0);
}

struct Counter(AtomicUsize);

#[async_trait::async_trait]
impl LookFetcher for Counter {
    async fn fetch(&self, _: &LookDescriptor) -> tether_library::Result<Vec<u8>> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Ok(CubeLut::identity(2).serialized().into_bytes())
    }
}

#[tokio::test]
async fn resolver_uses_cache_then_fetch() {
    let store = Arc::new(SessionStore::in_memory().unwrap());
    let desc = LookDescriptor::new("film", "Film", "film", 33, "/v1/looks/film.cube");
    store.save_look(&desc, None).unwrap();
    let counter = Arc::new(Counter(AtomicUsize::new(0)));
    let resolver = LookResolver::new(store.clone(), Some(counter.clone()));
    let a = resolver
        .lut(&LookStack::new(Some("film".into()), 1.0))
        .await
        .unwrap();
    let b = resolver
        .lut(&LookStack::new(Some("film".into()), 0.5))
        .await
        .unwrap();
    assert!(a.is_some() && b.is_some());
    assert_eq!(counter.0.load(Ordering::SeqCst), 1);
    assert!(store.cube("film").unwrap().is_some());
    assert!(resolver.lut(&LookStack::none()).await.unwrap().is_none());
}

#[test]
fn look_descriptor_decodes_server_shape() {
    let json = r#"{"id":"film-warm","name":"Film Warm","family":"film","version":1,"size":33,"sha256":"ab","cube_url":"/v1/looks/film-warm.cube","hint":{"warmth":0.3,"contrast":0.1,"saturation":-0.05}}"#;
    let d: LookDescriptor = serde_json::from_str(json).unwrap();
    assert_eq!(d.cube_url, "/v1/looks/film-warm.cube");
    assert_eq!(d.hint.unwrap().warmth, 0.3);
}

#[test]
fn neutral_recipe_is_identity_and_mono_is_grey() {
    let neutral = LookRecipe::default();
    for v in [[0.2f32, 0.5, 0.8], [0.0; 3], [1.0; 3]] {
        let o = neutral.apply(v);
        assert!(close(o[0], v[0]) && close(o[2], v[2]));
    }
    let mono = LookRecipe {
        saturation: -1.0,
        ..Default::default()
    }
    .apply([0.9, 0.2, 0.1]);
    assert!(close(mono[0], mono[1]) && close(mono[1], mono[2]));
    let warm = LookRecipe {
        warmth: 1.0,
        ..Default::default()
    }
    .apply([0.5, 0.5, 0.5]);
    assert!(warm[0] > warm[2]);
}

#[tokio::test]
async fn built_ins_install_and_resolve_without_network() {
    let store = Arc::new(SessionStore::in_memory().unwrap());
    BuiltInLooks::install(&store).unwrap();
    assert_eq!(store.looks().unwrap().len(), BuiltInLooks::ALL.len());
    let resolver = LookResolver::new(store.clone(), None);
    let lut = resolver
        .lut(&LookStack::new(Some("ot.mono".into()), 1.0))
        .await
        .unwrap();
    assert_eq!(lut.unwrap().size(), 25);
    BuiltInLooks::install(&store).unwrap();
    assert_eq!(
        store.looks().unwrap().len(),
        BuiltInLooks::ALL.len(),
        "re-install is idempotent"
    );
}

#[test]
fn color_match_moves_target_toward_reference() {
    let reference: Vec<[f32; 3]> = (0..200)
        .map(|i| [0.8, 0.5, 0.3].map(|c: f32| c + (i % 10) as f32 * 0.01))
        .collect();
    let target: Vec<[f32; 3]> = (0..200)
        .map(|i| [0.3, 0.5, 0.8].map(|c: f32| c + (i % 10) as f32 * 0.01))
        .collect();
    let lut = ColorMatch::lut(&reference, &target, 1.0, 25, "Match");
    // Sample the LUT at the target's average colour: it should come out warm.
    let n = lut.size();
    let idx = |r: usize, g: usize, b: usize| ((b * n + g) * n + r) * 3;
    let f = |x: f32| (x * (n - 1) as f32) as usize;
    let i = idx(f(0.34), f(0.54), f(0.84));
    assert!(
        lut.table()[i] > lut.table()[i + 2],
        "blue cast moved to the reference's warm cast"
    );
}

#[tokio::test]
async fn renders_and_matches_encoded_frames() {
    let warm = DynamicImage::ImageRgb8(ImageBuffer::from_fn(200, 100, |x, _| {
        Rgb([200, 120 + (x % 20) as u8, 60])
    }));
    let cool = DynamicImage::ImageRgb8(ImageBuffer::from_fn(200, 100, |x, _| {
        Rgb([60, 120 + (x % 20) as u8, 200])
    }));
    let warm_jpeg = imaging::encode_jpeg(&warm, 0.9).unwrap();
    let cool_jpeg = imaging::encode_jpeg(&cool, 0.9).unwrap();
    let lut = color_match_frames(&warm_jpeg, &cool_jpeg, 1.0, "Colour match").unwrap();
    let out = CpuLookRenderer::default()
        .render(cool_jpeg, Some(lut), 1.0, Some(50))
        .await
        .unwrap();
    let img = imaging::decode(&out, Some("x.jpg"), None)
        .unwrap()
        .to_rgb8();
    assert_eq!((img.width(), img.height()), (50, 25));
    let p = img.get_pixel(25, 12);
    assert!(p[0] > p[2], "the cool frame now looks warm: {p:?}");
}
