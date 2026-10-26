//! Export jobs (`Delivery/ExportJob.swift`).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::capture_item::MediaKind;
use crate::interop::naming::{FolderLayout, NamingTemplate};
use crate::looks::LookStack;
use crate::store::StoredFolderDestination;
use crate::swift_json::{self, Empty, Unnamed, UnnamedOpt};

/// Where a set of selects goes.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(into = "DestinationRepr", from = "DestinationRepr")]
pub enum ExportDestination {
    Photos,
    /// A local folder the app chose (the Mac counterpart of iOS "Files").
    Files,
    /// Handed to the share sheet by the app.
    Share,
    Ftp {
        destination_id: String,
    },
    /// A folder the user picked, kept as a security-scoped bookmark in
    /// [`StoredFolderDestination`].
    Folder {
        destination_id: String,
    },
}

#[derive(Serialize, Deserialize)]
enum DestinationRepr {
    #[serde(rename = "photos")]
    Photos(Empty),
    #[serde(rename = "files")]
    Files(Empty),
    #[serde(rename = "share")]
    Share(Empty),
    #[serde(rename = "ftp")]
    Ftp {
        #[serde(rename = "destinationID")]
        destination_id: String,
    },
    #[serde(rename = "folder")]
    Folder {
        #[serde(rename = "destinationID")]
        destination_id: String,
    },
}

impl From<ExportDestination> for DestinationRepr {
    fn from(d: ExportDestination) -> Self {
        match d {
            ExportDestination::Photos => Self::Photos(Empty {}),
            ExportDestination::Files => Self::Files(Empty {}),
            ExportDestination::Share => Self::Share(Empty {}),
            ExportDestination::Ftp { destination_id } => Self::Ftp { destination_id },
            ExportDestination::Folder { destination_id } => Self::Folder { destination_id },
        }
    }
}

impl From<DestinationRepr> for ExportDestination {
    fn from(d: DestinationRepr) -> Self {
        match d {
            DestinationRepr::Photos(_) => Self::Photos,
            DestinationRepr::Files(_) => Self::Files,
            DestinationRepr::Share(_) => Self::Share,
            DestinationRepr::Ftp { destination_id } => Self::Ftp { destination_id },
            DestinationRepr::Folder { destination_id } => Self::Folder { destination_id },
        }
    }
}

impl ExportDestination {
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::Photos => "Photos",
            Self::Files => "Files",
            Self::Share => "Share",
            Self::Ftp { .. } => "FTP",
            Self::Folder { .. } => "Folder",
        }
    }

    pub fn key(&self) -> &'static str {
        match self {
            Self::Photos => "photos",
            Self::Files => "files",
            Self::Share => "share",
            Self::Ftp { .. } => "ftp",
            Self::Folder { .. } => "folder",
        }
    }

    /// Anywhere files land as files (so sidecars and manifests make sense).
    pub fn delivers_files(&self) -> bool {
        !matches!(self, Self::Photos | Self::Share)
    }
}

/// What happens to RAW files on export (when `include_raw`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum RawOutput {
    /// Byte-for-byte original (plus sidecar): for Lightroom / Capture One.
    #[default]
    Original,
    /// Developed with the system RAW engine, then encoded.
    Jpeg,
    Heif,
    Tiff16,
}

impl RawOutput {
    pub const ALL: [RawOutput; 4] = [Self::Original, Self::Jpeg, Self::Heif, Self::Tiff16];

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Original => "Original RAW",
            Self::Jpeg => "JPEG",
            Self::Heif => "HEIF",
            Self::Tiff16 => "16-bit TIFF",
        }
    }

    /// Extension the delivered file gets (`None` = keep the RAW's own).
    pub fn file_extension(self) -> Option<&'static str> {
        match self {
            Self::Original => None,
            Self::Jpeg => Some("jpg"),
            Self::Heif => Some("heic"),
            Self::Tiff16 => Some("tif"),
        }
    }
}

fn default_true() -> bool {
    true
}

fn default_quality() -> f64 {
    0.92
}

/// How an export renders, names and annotates its files. Missing fields
/// (options saved before the interop fields existed) take their defaults.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExportOptions {
    #[serde(rename = "applyLook", default = "default_true")]
    pub apply_look: bool,
    /// `None` = full size.
    #[serde(
        rename = "maxLongEdge",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub max_long_edge: Option<u32>,
    #[serde(rename = "jpegQuality", default = "default_quality")]
    pub jpeg_quality: f64,
    #[serde(rename = "includeRAW", default)]
    pub include_raw: bool,
    #[serde(
        rename = "filenamePrefix",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub filename_prefix: Option<String>,
    /// Interop: how files are named and arranged, and what metadata rides along.
    #[serde(default = "NamingTemplate::original")]
    pub naming: NamingTemplate,
    #[serde(default)]
    pub layout: FolderLayout,
    /// XMP packet inside exported JPEGs.
    #[serde(rename = "embedMetadata", default = "default_true")]
    pub embed_metadata: bool,
    /// `.xmp` next to RAW (and JPEG when the profile asks).
    #[serde(rename = "writeSidecars", default = "default_true")]
    pub write_sidecars: bool,
    /// Session manifest JSON + CSV with the files.
    #[serde(rename = "writeManifest", default)]
    pub write_manifest: bool,
    /// Refresh only the XMP sidecars (ratings changed after the files were
    /// delivered, e.g. culling into a Capture One hot folder).
    #[serde(rename = "metadataOnly", default)]
    pub metadata_only: bool,
    /// RAW files: original, or developed to JPEG / HEIF / 16-bit TIFF.
    #[serde(rename = "rawOutput", default)]
    pub raw_output: RawOutput,
}

impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            apply_look: true,
            max_long_edge: None,
            jpeg_quality: 0.92,
            include_raw: false,
            filename_prefix: None,
            naming: NamingTemplate::original(),
            layout: FolderLayout::Flat,
            embed_metadata: true,
            write_sidecars: true,
            write_manifest: false,
            metadata_only: false,
            raw_output: RawOutput::Original,
        }
    }
}

/// A job's overall state.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(into = "StatusRepr", from = "StatusRepr")]
pub enum ExportStatus {
    Queued,
    Running,
    Paused,
    Completed,
    Failed(String),
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum StatusRepr {
    Queued(Empty),
    Running(Empty),
    Paused(Empty),
    Completed(Empty),
    Failed(Unnamed<String>),
}

impl From<ExportStatus> for StatusRepr {
    fn from(s: ExportStatus) -> Self {
        match s {
            ExportStatus::Queued => Self::Queued(Empty {}),
            ExportStatus::Running => Self::Running(Empty {}),
            ExportStatus::Paused => Self::Paused(Empty {}),
            ExportStatus::Completed => Self::Completed(Empty {}),
            ExportStatus::Failed(m) => Self::Failed(Unnamed { value: m }),
        }
    }
}

impl From<StatusRepr> for ExportStatus {
    fn from(s: StatusRepr) -> Self {
        match s {
            StatusRepr::Queued(_) => Self::Queued,
            StatusRepr::Running(_) => Self::Running,
            StatusRepr::Paused(_) => Self::Paused,
            StatusRepr::Completed(_) => Self::Completed,
            StatusRepr::Failed(u) => Self::Failed(u.value),
        }
    }
}

impl ExportStatus {
    /// The `status` column value.
    pub fn key(&self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Running => "running",
            Self::Paused => "paused",
            Self::Completed => "completed",
            Self::Failed(_) => "failed",
        }
    }

    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Completed | Self::Failed(_))
    }
}

/// One file's state within a job.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(into = "ItemStateRepr", from = "ItemStateRepr")]
pub enum ItemState {
    Pending,
    Uploading(f64),
    Done(Option<String>),
    Skipped(String),
    Failed(String),
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum ItemStateRepr {
    Pending(Empty),
    Uploading(Unnamed<f64>),
    Done(UnnamedOpt<String>),
    Skipped(Unnamed<String>),
    Failed(Unnamed<String>),
}

impl From<ItemState> for ItemStateRepr {
    fn from(s: ItemState) -> Self {
        match s {
            ItemState::Pending => Self::Pending(Empty {}),
            ItemState::Uploading(p) => Self::Uploading(Unnamed { value: p }),
            ItemState::Done(id) => Self::Done(UnnamedOpt { value: id }),
            ItemState::Skipped(m) => Self::Skipped(Unnamed { value: m }),
            ItemState::Failed(m) => Self::Failed(Unnamed { value: m }),
        }
    }
}

impl From<ItemStateRepr> for ItemState {
    fn from(s: ItemStateRepr) -> Self {
        match s {
            ItemStateRepr::Pending(_) => Self::Pending,
            ItemStateRepr::Uploading(u) => Self::Uploading(u.value),
            ItemStateRepr::Done(u) => Self::Done(u.value),
            ItemStateRepr::Skipped(u) => Self::Skipped(u.value),
            ItemStateRepr::Failed(u) => Self::Failed(u.value),
        }
    }
}

fn pending() -> ItemState {
    ItemState::Pending
}

/// One file in a job.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExportItem {
    /// Capture id.
    pub id: String,
    pub filename: String,
    pub kind: MediaKind,
    pub bytes: i64,
    #[serde(default = "pending")]
    pub state: ItemState,
    /// Photos local identifier / delivered path.
    #[serde(rename = "remoteID", default, skip_serializing_if = "Option::is_none")]
    pub remote_id: Option<String>,
    /// Interop: the name and relative folder the file is delivered under
    /// (set by the queue from `ExportOptions::naming` / `layout`).
    #[serde(
        rename = "exportFilename",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub export_filename: Option<String>,
    #[serde(
        rename = "exportDirectory",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub export_directory: Option<String>,
    /// True for a generated companion (XMP sidecar, manifest), not a photo.
    #[serde(rename = "isCompanion", default)]
    pub is_companion: bool,
}

impl ExportItem {
    pub fn new(
        id: impl Into<String>,
        filename: impl Into<String>,
        kind: MediaKind,
        bytes: i64,
    ) -> Self {
        Self {
            id: id.into(),
            filename: filename.into(),
            kind,
            bytes,
            state: ItemState::Pending,
            remote_id: None,
            export_filename: None,
            export_directory: None,
            is_companion: false,
        }
    }

    /// Final relative path under the destination root.
    pub fn delivered_relative_path(&self) -> String {
        let name = self.export_filename.as_deref().unwrap_or(&self.filename);
        match self.export_directory.as_deref() {
            Some(dir) if !dir.is_empty() => format!("{dir}/{name}"),
            _ => name.to_string(),
        }
    }

    pub fn is_done(&self) -> bool {
        matches!(self.state, ItemState::Done(_) | ItemState::Skipped(_))
    }

    pub fn is_failed(&self) -> bool {
        matches!(self.state, ItemState::Failed(_))
    }
}

/// A resumable, persisted export. Each item is attempted independently so a
/// killed app picks up exactly where it left off.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExportJob {
    pub id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    pub destination: ExportDestination,
    pub options: ExportOptions,
    pub look: LookStack,
    #[serde(rename = "createdAt", with = "swift_json::date")]
    pub created_at: DateTime<Utc>,
    pub status: ExportStatus,
    pub items: Vec<ExportItem>,
    pub attempts: i64,
}

impl ExportJob {
    pub fn new(
        session_id: impl Into<String>,
        destination: ExportDestination,
        options: ExportOptions,
        look: LookStack,
        items: Vec<ExportItem>,
    ) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            session_id: session_id.into(),
            destination,
            options,
            look,
            created_at: Utc::now(),
            status: ExportStatus::Queued,
            items,
            attempts: 0,
        }
    }

    pub fn progress(&self) -> f64 {
        if self.items.is_empty() {
            return 1.0;
        }
        let done: f64 = self
            .items
            .iter()
            .map(|i| match i.state {
                ItemState::Done(_) | ItemState::Skipped(_) => 1.0,
                ItemState::Uploading(p) => p,
                _ => 0.0,
            })
            .sum();
        done / self.items.len() as f64
    }

    pub fn pending_items(&self) -> Vec<&ExportItem> {
        self.items
            .iter()
            .filter(|i| !i.is_done() && !i.is_failed())
            .collect()
    }

    pub fn failed_items(&self) -> Vec<&ExportItem> {
        self.items.iter().filter(|i| i.is_failed()).collect()
    }
}

/// Options for the hot folder (`RoutingRules::live_folder_id`): originals
/// kept byte-for-byte under their camera names, RAW included, sidecars
/// written first, laid out the way the folder's tool expects.
pub struct HotFolder;

impl HotFolder {
    pub fn options(folder: &StoredFolderDestination, metadata_only: bool) -> ExportOptions {
        ExportOptions {
            apply_look: false,
            include_raw: true,
            naming: NamingTemplate::original(),
            layout: folder.suggested_layout().unwrap_or(FolderLayout::Flat),
            embed_metadata: true,
            write_sidecars: true,
            write_manifest: false,
            metadata_only,
            ..Default::default()
        }
    }
}
