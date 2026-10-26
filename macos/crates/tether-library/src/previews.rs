//! Proxy and thumbnail JPEGs for new captures (ports the app's
//! `ImageIOPreviewGenerator`).
//!
//! For RAW the embedded preview becomes the proxy, so the canvas never waits
//! for a full RAW demosaic, unless the embedded preview is small (some
//! bodies embed ~1 MP), in which case the RAW is developed properly (Core
//! Image, macOS). The proxy keeps the original's EXIF (orientation reset)
//! so the inspector shows camera facts.

use image::DynamicImage;

use crate::capture_item::MediaKind;
use crate::{imaging, util};

/// What the generator produced for one capture.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PreviewOutput {
    pub proxy_jpeg: Option<Vec<u8>>,
    pub thumbnail_jpeg: Option<Vec<u8>>,
    /// Upright pixel size of the original (0 when unknown).
    pub width: i64,
    pub height: i64,
}

/// Makes previews for a capture as it lands (the session crate calls it).
#[async_trait::async_trait]
pub trait PreviewGenerating: Send + Sync {
    async fn make_previews(
        &self,
        original: Vec<u8>,
        kind: MediaKind,
        filename: String,
    ) -> PreviewOutput;
}

/// Produces nothing (tests, video-only sessions).
#[derive(Debug, Clone, Copy, Default)]
pub struct NoPreviewGenerator;

#[async_trait::async_trait]
impl PreviewGenerating for NoPreviewGenerator {
    async fn make_previews(&self, _: Vec<u8>, _: MediaKind, _: String) -> PreviewOutput {
        PreviewOutput::default()
    }
}

/// The real generator: 2048 px proxies at 0.9, 320 px thumbnails at 0.8 (iOS sizes).
#[derive(Debug, Clone, Copy)]
pub struct ImagePreviewGenerator {
    pub proxy_max_pixels: u32,
    pub thumbnail_max_pixels: u32,
    pub proxy_quality: f64,
}

impl Default for ImagePreviewGenerator {
    fn default() -> Self {
        Self {
            proxy_max_pixels: 2048,
            thumbnail_max_pixels: 320,
            proxy_quality: 0.9,
        }
    }
}

impl ImagePreviewGenerator {
    /// Synchronous body of [`PreviewGenerating::make_previews`].
    pub fn make_previews_blocking(
        &self,
        original: &[u8],
        kind: MediaKind,
        filename: &str,
    ) -> PreviewOutput {
        if !kind.is_still() {
            return PreviewOutput::default();
        }
        let embedded = if kind == MediaKind::Raw {
            imaging::embedded_jpeg(original)
        } else {
            None
        };
        // Size of the original, upright.
        let (mut width, mut height) =
            imaging::dimensions(original, Some(filename)).unwrap_or((0, 0));

        let proxy_max = self.proxy_max_pixels;
        let proxy: Option<DynamicImage> = if kind == MediaKind::Raw {
            let preview = imaging::decode_embedded_preview(original, Some(proxy_max)).ok();
            let small = preview
                .as_ref()
                .is_none_or(|p| p.width().max(p.height()) < proxy_max * 6 / 10);
            #[cfg(target_os = "macos")]
            let developed = if small {
                imaging::develop_raw(original, util::path_extension(filename), Some(proxy_max))
            } else {
                None
            };
            #[cfg(not(target_os = "macos"))]
            let developed: Option<DynamicImage> = {
                let _ = (small, filename);
                None
            };
            developed.or(preview)
        } else {
            imaging::decode(original, Some(filename), Some(proxy_max)).ok()
        };
        let Some(proxy) = proxy else {
            return PreviewOutput {
                width: width as i64,
                height: height as i64,
                ..Default::default()
            };
        };
        if width == 0 || height == 0 {
            (width, height) = (proxy.width(), proxy.height());
        }
        // EXIF, TIFF and GPS from the original JPEG (or the RAW's embedded
        // preview), with the orientation reset: the proxy is upright.
        let exif_source = match (kind, embedded) {
            (MediaKind::Raw, Some(e)) => Some(e.bytes(original)),
            (MediaKind::Raw, None) => None,
            _ => Some(original),
        };
        let carried = exif_source.and_then(imaging::exif_segment).map(|mut seg| {
            if seg.len() > 10 {
                crate::interop::exif::set_orientation(&mut seg[10..], 1);
            }
            seg
        });
        let proxy_jpeg = imaging::encode_jpeg(&proxy, self.proxy_quality)
            .ok()
            .map(|j| match &carried {
                Some(seg) if seg.len() < 0xFFFF => imaging::insert_segment(&j, seg),
                _ => j,
            });
        let thumb = proxy.thumbnail(self.thumbnail_max_pixels, self.thumbnail_max_pixels);
        let thumbnail_jpeg = imaging::encode_jpeg(&thumb, 0.8).ok();
        PreviewOutput {
            proxy_jpeg,
            thumbnail_jpeg,
            width: width as i64,
            height: height as i64,
        }
    }
}

#[async_trait::async_trait]
impl PreviewGenerating for ImagePreviewGenerator {
    async fn make_previews(
        &self,
        original: Vec<u8>,
        kind: MediaKind,
        filename: String,
    ) -> PreviewOutput {
        let this = *self;
        tokio::task::spawn_blocking(move || this.make_previews_blocking(&original, kind, &filename))
            .await
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgb};

    #[test]
    fn jpeg_previews_keep_exif_and_sizes() {
        let img = DynamicImage::ImageRgb8(ImageBuffer::from_pixel(600, 400, Rgb([10u8, 120, 200])));
        let jpeg = imaging::encode_jpeg(&img, 0.9).unwrap();
        let exif = crate::interop::exif::minimal_jpeg_exif(
            "Canon",
            "EOS R5",
            chrono::Utc::now(),
            0.004,
            2.8,
            400,
        );
        let jpeg = imaging::insert_segment(&jpeg, &exif);
        let generator = ImagePreviewGenerator {
            proxy_max_pixels: 256,
            thumbnail_max_pixels: 64,
            proxy_quality: 0.9,
        };
        let out = generator.make_previews_blocking(&jpeg, MediaKind::Jpeg, "IMG_0001.JPG");
        assert_eq!((out.width, out.height), (600, 400));
        let proxy = out.proxy_jpeg.unwrap();
        let p = imaging::decode(&proxy, Some("p.jpg"), None).unwrap();
        assert_eq!(p.width(), 256);
        assert_eq!(
            crate::interop::exif::read(&proxy).unwrap().model.as_deref(),
            Some("EOS R5")
        );
        let t = imaging::decode(&out.thumbnail_jpeg.unwrap(), Some("t.jpg"), None).unwrap();
        assert_eq!(t.width(), 64);
        let none = ImagePreviewGenerator::default().make_previews_blocking(
            &jpeg,
            MediaKind::Video,
            "x.mov",
        );
        assert_eq!(none, PreviewOutput::default());
    }
}
