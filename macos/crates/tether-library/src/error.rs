use crate::delivery::ExportError;
use crate::interop::catalogs::CatalogError;
use crate::interop::exif::ExifError;
use crate::interop::xmp::XmpError;
use crate::library::LibraryError;
use crate::looks::CubeParseError;

/// Every failure the library can report. Module-specific errors keep their
/// own types (they are matched on in tests and in the UI) and convert here.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("SQLite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("I/O: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("image: {0}")]
    Image(#[from] image::ImageError),
    #[error(transparent)]
    Library(#[from] LibraryError),
    #[error(transparent)]
    Catalog(#[from] CatalogError),
    #[error(transparent)]
    Export(#[from] ExportError),
    #[error(transparent)]
    Cube(#[from] CubeParseError),
    #[error(transparent)]
    Xmp(#[from] XmpError),
    #[error(transparent)]
    Exif(#[from] ExifError),
    /// A path handed to the library was absolute or escaped its root.
    #[error("invalid path: {0}")]
    InvalidPath(String),
    /// An image could not be decoded or developed.
    #[error("could not decode image: {0}")]
    Decode(String),
    /// A failure reported by a platform hook (sink, uploader, fetcher).
    #[error("{0}")]
    Delivery(String),
}

pub type Result<T, E = Error> = std::result::Result<T, E>;
