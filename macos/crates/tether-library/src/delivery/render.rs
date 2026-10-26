//! The export renderer: applies a look (and a size limit) and encodes the
//! delivered file, developing RAW when the export asks for JPEG / HEIF /
//! 16-bit TIFF. Ports `CoreImageLookRenderer`'s `ExportRenderer` side.

use std::path::{Path, PathBuf};

use crate::capture_item::MediaKind;
use crate::delivery::job::{ExportItem, ExportOptions, RawOutput};
use crate::delivery::queue::ExportRenderer;
use crate::delivery::ExportError;
use crate::imaging;
use crate::looks::{apply_look, CubeLut, Interpolation};
use crate::{util, Error, Result};

/// Renders exports on the CPU; RAW development goes through Core Image on
/// macOS ([`imaging::core_image`]) and falls back to the camera's embedded
/// full-size JPEG elsewhere.
#[derive(Debug, Clone)]
pub struct ImageExportRenderer {
    pub interpolation: Interpolation,
    /// Where rendered files are written (each in its own sub-folder).
    pub temp_dir: PathBuf,
}

impl Default for ImageExportRenderer {
    fn default() -> Self {
        Self {
            interpolation: Interpolation::Trilinear,
            temp_dir: std::env::temp_dir(),
        }
    }
}

impl ImageExportRenderer {
    /// Synchronous body of [`ExportRenderer::render`].
    pub fn render_blocking(
        &self,
        original: &Path,
        item: &ExportItem,
        look: Option<&CubeLut>,
        options: &ExportOptions,
    ) -> Result<PathBuf> {
        // Untouched JPEG and HEIF go out byte-for-byte.
        if look.is_none()
            && options.max_long_edge.is_none()
            && matches!(item.kind, MediaKind::Jpeg | MediaKind::Heif)
        {
            return Ok(original.to_path_buf());
        }
        let data = std::fs::read(original)?;
        let is_raw = item.kind == MediaKind::Raw;
        let img = imaging::decode(&data, Some(&item.filename), options.max_long_edge)
            .map_err(|e| ExportError::RenderFailed(e.to_string()))?;
        let img = match look {
            Some(lut) => apply_look(img, lut, 1.0, self.interpolation),
            None => img,
        };
        let quality = options.jpeg_quality.clamp(0.3, 1.0);
        // The delivered extension always matches the bytes: HEIF stays HEIF;
        // developed RAW becomes what the export asked for.
        let format = if is_raw {
            options.raw_output
        } else if item.kind == MediaKind::Heif {
            RawOutput::Heif
        } else {
            RawOutput::Jpeg
        };
        let encoded = match format {
            RawOutput::Heif => imaging::encode_heif(&img, quality).ok_or_else(|| {
                ExportError::RenderFailed("HEIF encoding needs Core Image (macOS)".into())
            })?,
            RawOutput::Tiff16 => imaging::encode_tiff16(&img)?,
            RawOutput::Jpeg | RawOutput::Original => {
                let jpeg = imaging::encode_jpeg(&img, quality)?;
                // Keep the camera's EXIF on re-rendered JPEGs (upright now).
                let exif = if item.kind == MediaKind::Jpeg {
                    imaging::exif_segment(&data)
                } else {
                    None
                };
                match exif {
                    Some(mut seg) if seg.len() > 10 => {
                        crate::interop::exif::set_orientation(&mut seg[10..], 1);
                        imaging::insert_segment(&jpeg, &seg)
                    }
                    _ => jpeg,
                }
            }
        };
        let ext = format.file_extension().unwrap_or("jpg");
        let name = format!(
            "{}{}.{ext}",
            options.filename_prefix.as_deref().unwrap_or(""),
            util::delete_path_extension(&item.filename)
        );
        let dir = self
            .temp_dir
            .join(format!("tether-export-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir)?;
        let url = dir.join(name);
        std::fs::write(&url, encoded)?;
        Ok(url)
    }
}

#[async_trait::async_trait]
impl ExportRenderer for ImageExportRenderer {
    async fn render(
        &self,
        original: &Path,
        item: &ExportItem,
        look: Option<&CubeLut>,
        options: &ExportOptions,
    ) -> Result<PathBuf> {
        let (this, original, item, look, options) = (
            self.clone(),
            original.to_path_buf(),
            item.clone(),
            look.cloned(),
            options.clone(),
        );
        tokio::task::spawn_blocking(move || {
            this.render_blocking(&original, &item, look.as_ref(), &options)
        })
        .await
        .map_err(|e| Error::Decode(e.to_string()))?
    }
}
