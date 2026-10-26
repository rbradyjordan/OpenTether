//! Interop with other pro tools (`Interop/`): XMP, EXIF, naming templates and
//! folder layouts, file import plans, and Lightroom / Capture One catalog
//! read-back.

pub mod catalogs;
pub mod exif;
pub mod import_plan;
pub mod naming;
pub mod xmp;

pub use catalogs::{
    match_catalog, read_entries, CatalogChange, CatalogEntry, CatalogError, CatalogKind,
    CatalogMatch,
};
pub use exif::{ExifError, ExifSummary};
pub use import_plan::{FileImportPlan, ImportEntry};
pub use naming::{FolderLayout, ManifestRow, NamingContext, NamingTemplate, SessionManifest};
pub use xmp::{jpeg_xmp, MetadataProfile, XmpError, XmpPacket};
