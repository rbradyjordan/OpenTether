//! Delivery (`Delivery/`): export jobs, the resumable export queue, and the
//! export renderer.

pub mod job;
pub mod queue;
pub mod render;

pub use job::{
    ExportDestination, ExportItem, ExportJob, ExportOptions, ExportStatus, HotFolder, ItemState,
    RawOutput,
};
pub use queue::{
    CaptureFiles, DirectoryFiles, ExportEvent, ExportQueue, ExportQueueConfig, ExportRenderer,
    ExportSink, PassthroughRenderer, Uploader, UploaderFactory,
};
pub use render::ImageExportRenderer;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ExportError {
    #[error("The FTP destination for this export no longer exists.")]
    FtpDestinationMissing,
    #[error("Could not render the export: {0}")]
    RenderFailed(String),
}
