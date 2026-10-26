//! The JSON shapes of `docs/IPC.md` §6 (`app/ui/src/api/types.ts`), and
//! the conversions from the engine's own types. Everything here is
//! camelCase; optionals serialise as `null`, never omitted.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tether_library::delivery::{
    ExportDestination as LibDestination, ExportItem, ExportJob as LibJob,
    ExportOptions as LibOptions, ExportStatus, ItemState, RawOutput,
};
use tether_library::interop::xmp::MetadataProfile as LibProfile;
use tether_library::interop::{FolderLayout, NamingTemplate};
use tether_library::library::memory::{
    ExportMemory as LibExportMemory, SessionTemplate as LibTemplate, ViewState as LibViewState,
};
use tether_library::library::{
    CaptureFilter as LibFilter, CaptureSort, Collection as LibCollection, CollectionKind,
    DateRange as LibDateRange, ExportDestinationKey,
};
use tether_library::looks::{LookDescriptor as LibLook, LookHint, LookStack as LibLookStack};
use tether_library::store::{FolderKind, SessionCounts, StoredFtpDestination};
use tether_library::{
    CaptureFlag, CaptureItem as LibCapture, CaptureState as LibState, ColorLabel, ExposureSummary,
    MediaKind, RoutingRules as LibRouting, RoutingTarget, SessionStatus, ShootSession as LibSession,
};
use tether_net::{DiscoveredCamera as LibDiscovered, DiscoveryMethod};
use tether_ptp::device::PropertyForm as LibForm;
use tether_ptp::ptp::PtpValue;
use tether_ptp::{PropertyDescriptor as LibProperty, TetherProperty};
use tether_types::{CameraIdentity, CameraVendor, CaptureDestination, TransportKind};

use crate::diagnostics::{DiagnosticReport as LibReport, Outcome};
use crate::session::{ReconnectStrategy, TetherStatus};

// MARK: Captures

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CaptureState {
    Announced,
    Downloading { received: i64, total: Option<i64> },
    Ready,
    Failed { message: String },
}

impl From<&LibState> for CaptureState {
    fn from(s: &LibState) -> Self {
        match s {
            LibState::Announced => Self::Announced,
            LibState::Downloading { received, total } => Self::Downloading {
                received: *received,
                total: *total,
            },
            LibState::Ready => Self::Ready,
            LibState::Failed(m) => Self::Failed { message: m.clone() },
        }
    }
}

/// `ExposureSummary` with every field present (null when unknown).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Exposure {
    pub aperture: Option<String>,
    pub shutter: Option<String>,
    pub iso: Option<String>,
    pub compensation: Option<String>,
    pub white_balance: Option<String>,
}

impl From<&ExposureSummary> for Exposure {
    fn from(e: &ExposureSummary) -> Self {
        Self {
            aperture: e.aperture.clone(),
            shutter: e.shutter.clone(),
            iso: e.iso.clone(),
            compensation: e.compensation.clone(),
            white_balance: e.white_balance.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureItem {
    pub id: String,
    pub session_id: String,
    pub sequence: i64,
    pub filename: String,
    pub kind: MediaKind,
    pub bytes: i64,
    pub width: i64,
    pub height: i64,
    pub captured_at: DateTime<Utc>,
    pub received_at: DateTime<Utc>,
    pub rating: i64,
    pub flag: CaptureFlag,
    pub color_label: ColorLabel,
    pub state: CaptureState,
    pub pair_key: String,
    pub source: TransportKind,
    pub look_id: Option<String>,
    pub exposure: Option<Exposure>,
    pub camera_id: Option<String>,
    pub revision: u32,
}

/// The image revision: changes whenever the file, its proxy or its
/// thumbnail changes (or the capture becomes ready), never on download
/// progress. A stable 31-bit FNV-1a hash, so it survives restarts.
pub fn revision(c: &LibCapture) -> u32 {
    let mut h: u32 = 0x811c_9dc5;
    let mut feed = |s: &str| {
        for b in s.bytes().chain(std::iter::once(0u8)) {
            h ^= b as u32;
            h = h.wrapping_mul(0x0100_0193);
        }
    };
    feed(if c.state.is_ready() { "ready" } else { "pending" });
    feed(c.relative_path.as_deref().unwrap_or(""));
    feed(c.proxy_relative_path.as_deref().unwrap_or(""));
    feed(c.thumbnail_relative_path.as_deref().unwrap_or(""));
    (h & 0x7fff_ffff).max(1)
}

impl From<&LibCapture> for CaptureItem {
    fn from(c: &LibCapture) -> Self {
        Self {
            id: c.id.clone(),
            session_id: c.session_id.clone(),
            sequence: c.sequence,
            filename: c.filename.clone(),
            kind: c.kind,
            bytes: c.bytes,
            width: c.width,
            height: c.height,
            captured_at: c.captured_at,
            received_at: c.received_at,
            rating: c.rating,
            flag: c.flag,
            color_label: c.color_label,
            state: (&c.state).into(),
            pair_key: c.pair_key.clone(),
            source: c.source,
            look_id: c.look_id.clone(),
            exposure: c.exposure.as_ref().map(Exposure::from),
            camera_id: c.camera_id.clone(),
            revision: revision(c),
        }
    }
}

// MARK: Sessions

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RoutingRules {
    pub jpeg: RoutingTarget,
    pub raw: RoutingTarget,
    pub video: RoutingTarget,
    pub auto_export_picks: bool,
    pub ftp_destination_id: Option<String>,
    pub live_folder_id: Option<String>,
}

impl From<&LibRouting> for RoutingRules {
    fn from(r: &LibRouting) -> Self {
        Self {
            jpeg: r.jpeg,
            raw: r.raw,
            video: r.video,
            auto_export_picks: r.auto_export_picks,
            ftp_destination_id: r.ftp_destination_id.clone(),
            live_folder_id: r.live_folder_id.clone(),
        }
    }
}

impl From<RoutingRules> for LibRouting {
    fn from(r: RoutingRules) -> Self {
        Self {
            jpeg: r.jpeg,
            raw: r.raw,
            video: r.video,
            auto_export_picks: r.auto_export_picks,
            ftp_destination_id: r.ftp_destination_id,
            live_folder_id: r.live_folder_id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShootSession {
    pub id: String,
    pub name: String,
    pub created_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    pub status: SessionStatus,
    pub camera: Option<CameraIdentity>,
    pub transport: Option<TransportKind>,
    pub last_host: Option<String>,
    pub destination: CaptureDestination,
    pub routing: RoutingRules,
    pub look_id: Option<String>,
    pub look_strength: f64,
    pub show_newest_capture: bool,
    pub workflow_tag: Option<String>,
    pub capture_count: i64,
}

impl From<&LibSession> for ShootSession {
    fn from(s: &LibSession) -> Self {
        Self {
            id: s.id.clone(),
            name: s.name.clone(),
            created_at: s.created_at,
            ended_at: s.ended_at,
            status: s.status,
            camera: s.camera.clone(),
            transport: s.transport,
            last_host: s.last_host.clone(),
            destination: s.destination,
            routing: (&s.routing).into(),
            look_id: s.look_id.clone(),
            look_strength: s.look_strength,
            show_newest_capture: s.show_newest_capture,
            workflow_tag: s.workflow_tag.clone(),
            capture_count: s.capture_count,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Counts {
    pub total: i64,
    pub ready: i64,
    pub picks: i64,
    pub rejects: i64,
    pub rated: i64,
    pub failed: i64,
}

impl From<SessionCounts> for Counts {
    fn from(c: SessionCounts) -> Self {
        Self {
            total: c.total,
            ready: c.ready,
            picks: c.picks,
            rejects: c.rejects,
            rated: c.rated,
            failed: c.failed,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub session: ShootSession,
    pub counts: Counts,
    pub recent: Vec<CaptureItem>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewSessionDraft {
    pub name: String,
    pub workflow_tag: Option<String>,
    pub destination: CaptureDestination,
    pub routing: RoutingRules,
    pub look_id: Option<String>,
    pub template_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionDefaults {
    pub name: String,
    pub workflow_tag: Option<String>,
    pub destination: CaptureDestination,
    pub routing: RoutingRules,
    pub look_id: Option<String>,
    pub template_id: Option<String>,
    pub name_pattern: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LookStack {
    pub look_id: Option<String>,
    pub strength: f64,
}

impl From<&LibLookStack> for LookStack {
    fn from(l: &LibLookStack) -> Self {
        Self {
            look_id: l.look_id.clone(),
            strength: l.strength,
        }
    }
}

impl From<&LookStack> for LibLookStack {
    fn from(l: &LookStack) -> Self {
        LibLookStack::new(l.look_id.clone(), l.strength)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionTemplate {
    pub id: String,
    pub name: String,
    pub symbol: String,
    pub destination: CaptureDestination,
    pub routing: RoutingRules,
    pub look: LookStack,
    pub show_newest_capture: bool,
    pub auto_export_picks: bool,
    pub tags: Vec<String>,
    pub name_pattern: String,
    pub add_to_collection_id: Option<String>,
    pub use_count: i64,
    pub last_used: Option<DateTime<Utc>>,
}

impl From<&LibTemplate> for SessionTemplate {
    fn from(t: &LibTemplate) -> Self {
        Self {
            id: t.id.clone(),
            name: t.name.clone(),
            symbol: t.symbol.clone(),
            destination: t.destination,
            routing: (&t.routing).into(),
            look: (&t.look).into(),
            show_newest_capture: t.show_newest_capture,
            auto_export_picks: t.auto_export_picks,
            tags: t.tags.clone(),
            name_pattern: t.name_pattern.clone(),
            add_to_collection_id: t.add_to_collection_id.clone(),
            use_count: t.use_count,
            last_used: t.last_used,
        }
    }
}

impl From<SessionTemplate> for LibTemplate {
    fn from(t: SessionTemplate) -> Self {
        let mut out = LibTemplate::new(t.name);
        if !t.id.is_empty() {
            out.id = t.id;
        }
        out.symbol = t.symbol;
        out.destination = t.destination;
        out.routing = t.routing.into();
        out.look = (&t.look).into();
        out.show_newest_capture = t.show_newest_capture;
        out.auto_export_picks = t.auto_export_picks;
        out.tags = t.tags;
        out.name_pattern = t.name_pattern;
        out.add_to_collection_id = t.add_to_collection_id;
        out.use_count = t.use_count;
        out.last_used = t.last_used;
        out
    }
}

// MARK: Library

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DateRange {
    Today,
    Last7Days,
    Last30Days,
    Between { from: DateTime<Utc>, to: DateTime<Utc> },
}

impl From<LibDateRange> for DateRange {
    fn from(d: LibDateRange) -> Self {
        match d {
            LibDateRange::Today => Self::Today,
            LibDateRange::Last7Days => Self::Last7Days,
            LibDateRange::Last30Days => Self::Last30Days,
            LibDateRange::Between(from, to) => Self::Between { from, to },
        }
    }
}

impl From<DateRange> for LibDateRange {
    fn from(d: DateRange) -> Self {
        match d {
            DateRange::Today => Self::Today,
            DateRange::Last7Days => Self::Last7Days,
            DateRange::Last30Days => Self::Last30Days,
            DateRange::Between { from, to } => Self::Between(from, to),
        }
    }
}

/// Every field optional; absent / null means "any".
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CaptureFilter {
    pub min_rating: Option<i64>,
    pub max_rating: Option<i64>,
    pub flags: Option<Vec<CaptureFlag>>,
    pub colors: Option<Vec<ColorLabel>>,
    pub kinds: Option<Vec<MediaKind>>,
    pub session_ids: Option<Vec<String>>,
    pub camera_ids: Option<Vec<String>>,
    pub tags_all: Option<Vec<String>>,
    pub tags_any: Option<Vec<String>>,
    pub date_range: Option<DateRange>,
    pub text: Option<String>,
    pub ready_only: Option<bool>,
    pub has_look: Option<bool>,
    pub exported_to: Option<ExportDestinationKey>,
}

fn set<T: Ord + Clone>(v: &Option<Vec<T>>) -> Option<BTreeSet<T>> {
    v.as_ref()
        .filter(|v| !v.is_empty())
        .map(|v| v.iter().cloned().collect())
}

fn vec<T: Clone>(v: &Option<BTreeSet<T>>) -> Option<Vec<T>> {
    v.as_ref().map(|s| s.iter().cloned().collect())
}

impl CaptureFilter {
    /// The engine filter; `ready_only` falls back to `default_ready_only`.
    pub fn to_lib(&self, default_ready_only: bool) -> LibFilter {
        LibFilter {
            min_rating: self.min_rating,
            max_rating: self.max_rating,
            flags: set(&self.flags),
            colors: set(&self.colors),
            kinds: set(&self.kinds),
            session_ids: set(&self.session_ids),
            camera_ids: set(&self.camera_ids),
            tags_all: set(&self.tags_all),
            tags_any: set(&self.tags_any),
            date_range: self.date_range.map(Into::into),
            text: self
                .text
                .as_ref()
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty()),
            ready_only: self.ready_only.unwrap_or(default_ready_only),
            has_look: self.has_look,
            exported_to: self.exported_to,
        }
    }
}

impl From<&LibFilter> for CaptureFilter {
    fn from(f: &LibFilter) -> Self {
        Self {
            min_rating: f.min_rating,
            max_rating: f.max_rating,
            flags: vec(&f.flags),
            colors: vec(&f.colors),
            kinds: vec(&f.kinds),
            session_ids: vec(&f.session_ids),
            camera_ids: vec(&f.camera_ids),
            tags_all: vec(&f.tags_all),
            tags_any: vec(&f.tags_any),
            date_range: f.date_range.map(Into::into),
            text: f.text.clone(),
            ready_only: Some(f.ready_only),
            has_look: f.has_look,
            exported_to: f.exported_to,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Collection {
    pub id: String,
    pub name: String,
    pub kind: CollectionKind,
    pub rule: Option<CaptureFilter>,
    pub symbol: String,
    pub tint: ColorLabel,
    pub is_pinned: bool,
    pub sort_order: i64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub is_built_in: bool,
}

impl From<&LibCollection> for Collection {
    fn from(c: &LibCollection) -> Self {
        Self {
            id: c.id.clone(),
            name: c.name.clone(),
            kind: c.kind,
            rule: c.rule.as_ref().map(CaptureFilter::from),
            symbol: c.symbol.clone(),
            tint: c.tint,
            is_pinned: c.is_pinned,
            sort_order: c.sort_order,
            created_at: c.created_at,
            updated_at: c.updated_at,
            is_built_in: c.is_built_in,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "camelCase")]
pub enum LibrarySourceTag {
    Collection(String),
    Session(String),
    Camera(String),
}

/// `{ kind: "collection" | "session" | "camera", id }`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct LibrarySource {
    pub kind: SourceKind,
    pub id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SourceKind {
    Collection,
    Session,
    Camera,
}

impl LibrarySource {
    /// `sourceKey(source)` in the UI.
    pub fn key(&self) -> String {
        let kind = match self.kind {
            SourceKind::Collection => "collection",
            SourceKind::Session => "session",
            SourceKind::Camera => "camera",
        };
        format!("{kind}:{}", self.id)
    }

    pub fn to_core(&self) -> crate::app_core::LibrarySource {
        use crate::app_core::LibrarySource as S;
        match self.kind {
            SourceKind::Collection => S::Collection(self.id.clone()),
            SourceKind::Session => S::Session(self.id.clone()),
            SourceKind::Camera => S::Camera(self.id.clone()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LibrarySources {
    pub built_ins: Vec<Collection>,
    pub pinned: Vec<Collection>,
    pub manual: Vec<Collection>,
    pub smart: Vec<Collection>,
    pub sessions: Vec<ShootSession>,
    pub cameras: Vec<CameraIdentity>,
    pub counts: BTreeMap<String, i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryQuery {
    pub source: LibrarySource,
    #[serde(default)]
    pub filter: CaptureFilter,
    pub sort: CaptureSort,
    #[serde(default)]
    pub offset: i64,
    pub limit: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryPage {
    pub items: Vec<CaptureItem>,
    pub total: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportHistoryEntry {
    pub destination: String,
    pub at: DateTime<Utc>,
    pub remote_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExifSummary {
    pub make: Option<String>,
    pub model: Option<String>,
    pub lens: Option<String>,
    pub exposure_line: Option<String>,
    pub date_time_original: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureDetails {
    pub id: String,
    pub tags: Vec<String>,
    pub collection_ids: Vec<String>,
    pub export_history: Vec<ExportHistoryEntry>,
    pub exif: Option<ExifSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UndoState {
    pub undo_title: Option<String>,
    pub redo_title: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UndoResult {
    pub title: String,
    pub count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CatalogKind {
    Lightroom,
    CaptureOne,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogChange {
    pub capture_id: String,
    pub filename: String,
    pub rating: Option<i64>,
    pub flag: Option<CaptureFlag>,
    pub label: Option<ColorLabel>,
    pub new_keywords: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogPreview {
    pub path: String,
    pub name: String,
    pub kind: CatalogKind,
    pub changes: Vec<CatalogChange>,
    pub unmatched: Vec<String>,
    pub open_elsewhere: bool,
}

// MARK: Looks

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LookDescriptor {
    pub id: String,
    pub name: String,
    pub family: String,
    pub version: i64,
    pub size: i64,
    pub hint: Option<LookHint>,
}

impl From<&LibLook> for LookDescriptor {
    fn from(l: &LibLook) -> Self {
        Self {
            id: l.id.clone(),
            name: l.name.clone(),
            family: l.family.clone(),
            version: l.version,
            size: l.size,
            hint: l.hint.clone(),
        }
    }
}

// MARK: Export

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ExportDestination {
    Photos,
    Files,
    #[serde(rename_all = "camelCase")]
    Ftp {
        destination_id: String,
    },
    #[serde(rename_all = "camelCase")]
    Folder {
        destination_id: String,
    },
}

impl From<&LibDestination> for ExportDestination {
    fn from(d: &LibDestination) -> Self {
        match d {
            LibDestination::Photos => Self::Photos,
            LibDestination::Files | LibDestination::Share => Self::Files,
            LibDestination::Ftp { destination_id } => Self::Ftp {
                destination_id: destination_id.clone(),
            },
            LibDestination::Folder { destination_id } => Self::Folder {
                destination_id: destination_id.clone(),
            },
        }
    }
}

impl From<&ExportDestination> for LibDestination {
    fn from(d: &ExportDestination) -> Self {
        match d {
            ExportDestination::Photos => Self::Photos,
            ExportDestination::Files => Self::Files,
            ExportDestination::Ftp { destination_id } => Self::Ftp {
                destination_id: destination_id.clone(),
            },
            ExportDestination::Folder { destination_id } => Self::Folder {
                destination_id: destination_id.clone(),
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportOptions {
    pub apply_look: bool,
    pub max_long_edge: Option<u32>,
    pub jpeg_quality: f64,
    pub include_raw: bool,
    pub naming_pattern: String,
    pub layout: FolderLayout,
    pub embed_metadata: bool,
    pub write_sidecars: bool,
    pub write_manifest: bool,
    pub raw_output: RawOutput,
}

impl From<&LibOptions> for ExportOptions {
    fn from(o: &LibOptions) -> Self {
        Self {
            apply_look: o.apply_look,
            max_long_edge: o.max_long_edge,
            jpeg_quality: o.jpeg_quality,
            include_raw: o.include_raw,
            naming_pattern: o.naming.pattern.clone(),
            layout: o.layout,
            embed_metadata: o.embed_metadata,
            write_sidecars: o.write_sidecars,
            write_manifest: o.write_manifest,
            raw_output: o.raw_output,
        }
    }
}

impl From<&ExportOptions> for LibOptions {
    fn from(o: &ExportOptions) -> Self {
        Self {
            apply_look: o.apply_look,
            max_long_edge: o.max_long_edge,
            jpeg_quality: o.jpeg_quality,
            include_raw: o.include_raw,
            filename_prefix: None,
            naming: if o.naming_pattern.trim().is_empty() {
                NamingTemplate::original()
            } else {
                NamingTemplate::new(o.naming_pattern.clone())
            },
            layout: o.layout,
            embed_metadata: o.embed_metadata,
            write_sidecars: o.write_sidecars,
            write_manifest: o.write_manifest,
            metadata_only: false,
            raw_output: o.raw_output,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ExportScope {
    All,
    Picks,
    Rated {
        min: i64,
    },
    #[serde(rename_all = "camelCase")]
    Selected {
        capture_id: String,
    },
    Selection {
        ids: Vec<String>,
    },
    #[serde(rename_all = "camelCase")]
    Collection {
        collection_id: String,
    },
}

impl ExportScope {
    /// The id `ExportMemory.scope` remembers.
    pub fn memory_id(&self) -> String {
        match self {
            Self::All => "all".into(),
            Self::Picks => "picks".into(),
            Self::Rated { min } => format!("rated{min}"),
            Self::Selected { .. } => "selected".into(),
            Self::Selection { .. } => "selection".into(),
            Self::Collection { .. } => "collection".into(),
        }
    }

    pub fn from_memory_id(id: &str) -> Self {
        match id {
            "picks" => Self::Picks,
            s if s.starts_with("rated") => Self::Rated {
                min: s[5..].parse().unwrap_or(3),
            },
            _ => Self::All,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportRequest {
    pub session_id: Option<String>,
    pub capture_ids: Option<Vec<String>>,
    pub scope: ExportScope,
    pub destination: ExportDestination,
    pub options: ExportOptions,
    pub look: Option<LookStack>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportPlan {
    pub photo_count: usize,
    pub raw_count: usize,
    pub preview_paths: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ExportItemState {
    Pending,
    Uploading { progress: f64 },
    Done { path: Option<String> },
    Skipped { reason: String },
    Failed { reason: String },
}

impl From<&ItemState> for ExportItemState {
    fn from(s: &ItemState) -> Self {
        match s {
            ItemState::Pending => Self::Pending,
            ItemState::Uploading(p) => Self::Uploading { progress: *p },
            ItemState::Done(p) => Self::Done { path: p.clone() },
            ItemState::Skipped(r) => Self::Skipped { reason: r.clone() },
            ItemState::Failed(r) => Self::Failed { reason: r.clone() },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportJobItem {
    pub id: String,
    pub filename: String,
    pub kind: MediaKind,
    pub bytes: i64,
    pub state: ExportItemState,
    pub delivered_path: String,
    pub is_companion: bool,
}

impl From<&ExportItem> for ExportJobItem {
    fn from(i: &ExportItem) -> Self {
        Self {
            id: i.id.clone(),
            filename: i.filename.clone(),
            kind: i.kind,
            bytes: i.bytes,
            state: (&i.state).into(),
            delivered_path: i.delivered_relative_path(),
            is_companion: i.is_companion,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ExportJobStatus {
    Queued,
    Running,
    Paused,
    Completed,
    Failed { message: String },
}

impl From<&ExportStatus> for ExportJobStatus {
    fn from(s: &ExportStatus) -> Self {
        match s {
            ExportStatus::Queued => Self::Queued,
            ExportStatus::Running => Self::Running,
            ExportStatus::Paused => Self::Paused,
            ExportStatus::Completed => Self::Completed,
            ExportStatus::Failed(m) => Self::Failed { message: m.clone() },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportJob {
    pub id: String,
    pub session_id: String,
    pub destination: ExportDestination,
    pub destination_name: String,
    pub options: ExportOptions,
    pub look: LookStack,
    pub created_at: DateTime<Utc>,
    pub status: ExportJobStatus,
    pub items: Vec<ExportJobItem>,
    pub progress: f64,
    pub attempts: i64,
}

impl ExportJob {
    /// `destination_name` comes from the saved FTP / folder destinations.
    pub fn new(j: &LibJob, destination_name: String) -> Self {
        Self {
            id: j.id.clone(),
            session_id: j.session_id.clone(),
            destination: (&j.destination).into(),
            destination_name,
            options: (&j.options).into(),
            look: (&j.look).into(),
            created_at: j.created_at,
            status: (&j.status).into(),
            items: j.items.iter().map(ExportJobItem::from).collect(),
            progress: j.progress(),
            attempts: j.attempts,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FtpDestination {
    #[serde(default)]
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub security: tether_net::FtpSecurity,
    pub passive: bool,
    pub remote_directory: String,
}

impl From<&StoredFtpDestination> for FtpDestination {
    fn from(d: &StoredFtpDestination) -> Self {
        Self {
            id: d.id.clone(),
            name: d.name.clone(),
            host: d.host.clone(),
            port: d.port,
            username: d.username.clone(),
            security: serde_json::from_value(Value::String(d.security.clone()))
                .unwrap_or(tether_net::FtpSecurity::ExplicitTls),
            passive: d.passive,
            remote_directory: d.remote_directory.clone(),
        }
    }
}

/// The raw value the store keeps for an `FtpSecurity`.
pub fn ftp_security_raw(s: tether_net::FtpSecurity) -> String {
    match serde_json::to_value(s) {
        Ok(Value::String(s)) => s,
        _ => "explicitTLS".into(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderDestination {
    pub id: String,
    pub name: String,
    pub path: String,
    pub kind: FolderKind,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportMemory {
    pub destination: ExportDestination,
    pub options: ExportOptions,
    pub scope: String,
}

impl From<&LibExportMemory> for ExportMemory {
    fn from(m: &LibExportMemory) -> Self {
        Self {
            destination: (&m.destination).into(),
            options: (&m.options).into(),
            scope: m.scope.clone(),
        }
    }
}

// MARK: Connect

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsbCandidate {
    pub id: String,
    pub name: String,
    pub vendor_guess: CameraVendor,
    pub usb_vendor_id: i32,
    pub usb_product_id: i32,
    pub serial_number: Option<String>,
}

impl From<&crate::events::UsbDeviceDto> for UsbCandidate {
    fn from(d: &crate::events::UsbDeviceDto) -> Self {
        Self {
            id: d.id.clone(),
            name: d.name.clone(),
            vendor_guess: d.vendor_guess,
            usb_vendor_id: d.usb_vendor_id,
            usb_product_id: d.usb_product_id,
            serial_number: d.serial_number.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsbAuthorization {
    #[serde(rename = "canSendPTP")]
    pub can_send_ptp: bool,
    pub is_denied: bool,
    pub summary: String,
}

impl From<&crate::events::UsbAuthorizationDto> for UsbAuthorization {
    fn from(a: &crate::events::UsbAuthorizationDto) -> Self {
        Self {
            can_send_ptp: a.can_send_ptp,
            is_denied: a.is_denied,
            summary: a.summary.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredCamera {
    pub id: String,
    pub name: String,
    pub vendor: Option<CameraVendor>,
    pub host: String,
    pub port: u16,
    pub method: DiscoveryMethod,
    pub transport: TransportKind,
    pub last_seen: DateTime<Utc>,
    pub is_controllable: bool,
}

impl From<&LibDiscovered> for DiscoveredCamera {
    fn from(c: &LibDiscovered) -> Self {
        Self {
            id: c.id.clone(),
            name: c.name.clone(),
            vendor: c.vendor,
            host: c.host.clone(),
            port: c.port,
            method: c.method,
            transport: c.transport,
            last_seen: c.last_seen,
            is_controllable: c.is_controllable(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveryState {
    pub running: bool,
    pub cameras: Vec<DiscoveredCamera>,
    pub errors: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KnownCamera {
    pub camera: CameraIdentity,
    pub host: Option<String>,
    pub last_seen: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConnectStep {
    Link,
    Session,
    Identify,
    Prepare,
    Ready,
}

impl ConnectStep {
    pub const ALL: [ConnectStep; 5] = [
        Self::Link,
        Self::Session,
        Self::Identify,
        Self::Prepare,
        Self::Ready,
    ];

    /// The engine's finer steps folded onto the five the UI lists.
    pub fn from_engine(s: crate::session::connect::ConnectStep) -> Self {
        use crate::session::connect::ConnectStep as E;
        match s {
            E::Link | E::InitCommand | E::InitEvent => Self::Link,
            E::Session => Self::Session,
            E::DeviceInfo => Self::Identify,
            E::VendorGate => Self::Prepare,
            E::Ready => Self::Ready,
        }
    }

    pub fn title(self, transport: TransportKind) -> &'static str {
        match self {
            Self::Link => match transport {
                TransportKind::Usb => "Open the USB connection",
                TransportKind::FtpPush => "Start the FTP server",
                _ => "Reach the camera",
            },
            Self::Session => match transport {
                TransportKind::RicohHttp | TransportKind::Http => "Say hello over HTTP",
                _ => "Open a PTP session",
            },
            Self::Identify => "Read the camera's identity",
            Self::Prepare => "Switch to remote mode",
            Self::Ready => "Ready to shoot",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StepState {
    Pending,
    Running,
    Done,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectStepState {
    pub step: ConnectStep,
    pub title: String,
    pub state: StepState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectProgress {
    pub attempt_id: String,
    pub transport: TransportKind,
    pub steps: Vec<ConnectStepState>,
    pub failure: Option<String>,
}

impl ConnectProgress {
    pub fn new(transport: TransportKind) -> Self {
        Self {
            attempt_id: uuid::Uuid::new_v4().to_string(),
            transport,
            steps: ConnectStep::ALL
                .iter()
                .map(|s| ConnectStepState {
                    step: *s,
                    title: s.title(transport).into(),
                    state: StepState::Pending,
                })
                .collect(),
            failure: None,
        }
    }

    /// `step` is running: every earlier step is done.
    pub fn advance(&mut self, step: ConnectStep) {
        let at = ConnectStep::ALL.iter().position(|s| *s == step).unwrap_or(0);
        for (i, s) in self.steps.iter_mut().enumerate() {
            if i < at {
                s.state = StepState::Done;
            } else if i == at {
                s.state = if step == ConnectStep::Ready {
                    StepState::Done
                } else {
                    StepState::Running
                };
            }
        }
    }

    pub fn fail(&mut self, message: String) {
        match self
            .steps
            .iter_mut()
            .find(|s| s.state == StepState::Running)
        {
            Some(s) => s.state = StepState::Failed,
            None => {
                if let Some(s) = self
                    .steps
                    .iter_mut()
                    .find(|s| s.state == StepState::Pending)
                {
                    s.state = StepState::Failed;
                }
            }
        }
        self.failure = Some(message);
    }

    pub fn finish(&mut self) {
        for s in &mut self.steps {
            s.state = StepState::Done;
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkInfo {
    pub ssid: Option<String>,
    pub ssid_authorization: String,
    pub local_addresses: Vec<String>,
    pub camera_network_vendor: Option<CameraVendor>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FtpReceivedFile {
    pub id: String,
    pub name: String,
    pub bytes: u64,
    pub from: String,
    pub at: DateTime<Utc>,
    pub duration_seconds: f64,
}

impl From<&crate::events::FtpFileDto> for FtpReceivedFile {
    fn from(f: &crate::events::FtpFileDto) -> Self {
        Self {
            id: format!("{}-{}", f.at.timestamp_millis(), f.name),
            name: f.name.clone(),
            bytes: f.bytes,
            from: f.from.clone(),
            at: f.at,
            duration_seconds: f.duration_ms as f64 / 1000.0,
        }
    }
}

// `PartialEq` only: durations are floats.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FtpReceiverStatus {
    pub running: bool,
    pub username: String,
    pub password: String,
    pub port: u16,
    pub bound_port: Option<u16>,
    pub addresses: Vec<String>,
    pub clients: usize,
    pub last_error: Option<String>,
    pub received: Vec<FtpReceivedFile>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DiagnosticOutcome {
    Pending,
    Running,
    Pass { detail: String },
    Warn { detail: String },
    Fail { detail: String },
    Skipped { detail: String },
}

impl From<&Outcome> for DiagnosticOutcome {
    fn from(o: &Outcome) -> Self {
        match o {
            Outcome::Pending => Self::Pending,
            Outcome::Running => Self::Running,
            Outcome::Pass(d) => Self::Pass { detail: d.clone() },
            Outcome::Warn(d) => Self::Warn { detail: d.clone() },
            Outcome::Fail(d) => Self::Fail { detail: d.clone() },
            Outcome::Skipped(d) => Self::Skipped { detail: d.clone() },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticCheck {
    pub id: String,
    pub title: String,
    pub tip: String,
    pub outcome: DiagnosticOutcome,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticReport {
    pub id: String,
    pub wired: bool,
    pub verdict: String,
    pub checks: Vec<DiagnosticCheck>,
    pub finished_at: Option<DateTime<Utc>>,
    pub share_text: String,
}

impl DiagnosticReport {
    pub fn new(id: &str, wired: bool, r: &LibReport) -> Self {
        Self {
            id: id.to_string(),
            wired,
            verdict: r.verdict().to_string(),
            checks: r
                .checks
                .iter()
                .map(|c| DiagnosticCheck {
                    id: c.id.clone(),
                    title: c.title.clone(),
                    tip: c.tip.clone(),
                    outcome: (&c.outcome).into(),
                })
                .collect(),
            finished_at: r.finished_at,
            share_text: r.share_text(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PtpLogLine {
    pub at: DateTime<Utc>,
    pub direction: String,
    pub text: String,
}

// MARK: Shoot

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ShootStatus {
    Idle,
    Connecting,
    Preparing,
    Ready,
    Capturing,
    Reconnecting,
    Disconnected { reason: String },
    Ended,
}

impl From<&TetherStatus> for ShootStatus {
    fn from(s: &TetherStatus) -> Self {
        match s {
            TetherStatus::Idle => Self::Idle,
            TetherStatus::Connecting => Self::Connecting,
            TetherStatus::Preparing => Self::Preparing,
            TetherStatus::Ready => Self::Ready,
            TetherStatus::Capturing => Self::Capturing,
            TetherStatus::Reconnecting => Self::Reconnecting,
            TetherStatus::Disconnected(r) => Self::Disconnected { reason: r.clone() },
            TetherStatus::Ended => Self::Ended,
        }
    }
}

/// A PTP value as JSON: integers stay numbers, strings stay strings.
pub fn ptp_json(v: &PtpValue) -> Value {
    if let Some(i) = v.int_value() {
        return Value::from(i);
    }
    if let Some(s) = v.string_value() {
        return Value::from(s);
    }
    Value::from(format!("{v:?}"))
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PropertyChoice {
    pub raw: Value,
    pub display: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PropertyForm {
    Choices { choices: Vec<PropertyChoice> },
    Range { min: f64, max: f64, step: f64 },
    Other,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PropertyDescriptor {
    pub property: TetherProperty,
    pub raw: Value,
    pub display: String,
    pub is_writable: bool,
    pub form: PropertyForm,
}

impl From<&LibProperty> for PropertyDescriptor {
    fn from(p: &LibProperty) -> Self {
        Self {
            property: p.property,
            raw: ptp_json(&p.raw),
            display: p.display.clone(),
            is_writable: p.is_writable,
            form: match &p.form {
                LibForm::Choices(c) => PropertyForm::Choices {
                    choices: c
                        .iter()
                        .map(|c| PropertyChoice {
                            raw: ptp_json(&c.raw),
                            display: c.display.clone(),
                        })
                        .collect(),
                },
                LibForm::Range { min, max, step } => PropertyForm::Range {
                    min: *min,
                    max: *max,
                    step: *step,
                },
                LibForm::Other => PropertyForm::Other,
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraMemoryOffer {
    pub look: LookStack,
    pub look_name: String,
    pub destination: CaptureDestination,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShootState {
    pub session: ShootSession,
    pub identity: Option<CameraIdentity>,
    pub status: ShootStatus,
    pub items: Vec<CaptureItem>,
    pub properties: Vec<PropertyDescriptor>,
    pub selected_item_id: Option<String>,
    pub downloads_in_flight: usize,
    pub live_view_active: bool,
    pub look: LookStack,
    pub reconnect: ReconnectStrategy,
    pub restore_offer: Option<CameraMemoryOffer>,
    pub is_demo: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FocusResult {
    Focused,
    Failed,
    Unconfirmed,
}

impl From<tether_ptp::FocusResult> for FocusResult {
    fn from(f: tether_ptp::FocusResult) -> Self {
        match f {
            tether_ptp::FocusResult::Focused => Self::Focused,
            tether_ptp::FocusResult::Failed => Self::Failed,
            tether_ptp::FocusResult::Unconfirmed => Self::Unconfirmed,
        }
    }
}

// MARK: Settings / memory

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSettings {
    pub has_onboarded: bool,
    pub ftp_username: String,
    pub ftp_password: String,
    pub ftp_port: u16,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettingsPatch {
    pub has_onboarded: Option<bool>,
    pub ftp_username: Option<String>,
    pub ftp_password: Option<String>,
    pub ftp_port: Option<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataProfile {
    pub creator: Option<String>,
    pub copyright: Option<String>,
    pub caption_template: Option<String>,
    pub hierarchical_root: Option<String>,
    pub session_as_keyword: bool,
    pub embed_in_jpeg: bool,
    pub write_sidecars_for_raw: bool,
    pub write_sidecars_for_jpeg: bool,
    pub read_incoming_xmp: bool,
}

impl From<&LibProfile> for MetadataProfile {
    fn from(p: &LibProfile) -> Self {
        Self {
            creator: p.creator.clone(),
            copyright: p.copyright.clone(),
            caption_template: p.caption_template.clone(),
            hierarchical_root: p.hierarchical_root.clone(),
            session_as_keyword: p.session_as_keyword,
            embed_in_jpeg: p.embed_in_jpeg,
            write_sidecars_for_raw: p.write_sidecars_for_raw,
            write_sidecars_for_jpeg: p.write_sidecars_for_jpeg,
            read_incoming_xmp: p.read_incoming_xmp,
        }
    }
}

impl From<MetadataProfile> for LibProfile {
    fn from(p: MetadataProfile) -> Self {
        let blank = |s: Option<String>| s.filter(|s| !s.trim().is_empty());
        Self {
            creator: blank(p.creator),
            copyright: blank(p.copyright),
            caption_template: blank(p.caption_template),
            hierarchical_root: blank(p.hierarchical_root),
            session_as_keyword: p.session_as_keyword,
            embed_in_jpeg: p.embed_in_jpeg,
            write_sidecars_for_raw: p.write_sidecars_for_raw,
            write_sidecars_for_jpeg: p.write_sidecars_for_jpeg,
            read_incoming_xmp: p.read_incoming_xmp,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ViewState {
    #[serde(default)]
    pub filter: CaptureFilter,
    pub sort: CaptureSort,
    pub columns: i64,
    pub stack_pairs: bool,
}

impl From<&LibViewState> for ViewState {
    fn from(v: &LibViewState) -> Self {
        Self {
            filter: (&v.filter).into(),
            sort: v.sort,
            columns: v.columns,
            stack_pairs: v.stack_pairs,
        }
    }
}

impl From<&ViewState> for LibViewState {
    fn from(v: &ViewState) -> Self {
        Self {
            filter: v.filter.to_lib(true),
            sort: v.sort,
            columns: v.columns,
            stack_pairs: v.stack_pairs,
            ..Default::default()
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Recents {
    pub tags: Vec<String>,
    pub collection_ids: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PermissionKind {
    LocalNetwork,
    Photos,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PermissionState {
    Granted,
    Denied,
    NotDetermined,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToastAction {
    pub title: String,
    pub command: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToastMessage {
    pub id: String,
    pub text: String,
    pub symbol: String,
    pub action: Option<ToastAction>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct XmpPreview {
    pub filename: Option<String>,
    pub packet: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestPaths {
    pub json_path: String,
    pub csv_path: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Imported {
    pub imported: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Added {
    pub added: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Applied {
    pub applied: usize,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn capture_matches_the_contract() {
        let mut c = LibCapture::new("s", 7, 1, "A.JPG", MediaKind::Jpeg, 3, TransportKind::Usb);
        c.state = LibState::Downloading {
            received: 1,
            total: Some(3),
        };
        let v = serde_json::to_value(CaptureItem::from(&c)).unwrap();
        assert_eq!(v["sessionId"], "s");
        assert_eq!(v["state"], json!({"kind": "downloading", "received": 1, "total": 3}));
        assert_eq!(v["lookId"], Value::Null);
        assert_eq!(v["exposure"], Value::Null);
        assert!(v["revision"].as_u64().unwrap() > 0);
        let before = revision(&c);
        c.state = LibState::Downloading {
            received: 2,
            total: Some(3),
        };
        assert_eq!(revision(&c), before, "progress doesn't change the revision");
        c.state = LibState::Ready;
        c.relative_path = Some("a/A.JPG".into());
        assert_ne!(revision(&c), before);
    }

    #[test]
    fn filter_round_trips_with_contract_names() {
        let f: CaptureFilter = serde_json::from_value(json!({
            "minRating": 3, "sessionIds": ["x"], "dateRange": {"kind": "between", "from": "2026-01-01T00:00:00Z", "to": "2026-01-02T00:00:00Z"}
        }))
        .unwrap();
        let lib = f.to_lib(false);
        assert!(!lib.ready_only);
        assert_eq!(lib.session_ids.as_ref().unwrap().len(), 1);
        let back = serde_json::to_value(CaptureFilter::from(&lib)).unwrap();
        assert_eq!(back["dateRange"]["kind"], "between");
        assert_eq!(back["readyOnly"], false);
        assert_eq!(serde_json::to_value(DateRange::Last7Days).unwrap(), json!({"kind": "last7Days"}));
    }

    #[test]
    fn export_shapes() {
        let d: ExportDestination =
            serde_json::from_value(json!({"kind": "ftp", "destinationId": "f"})).unwrap();
        assert_eq!(
            d,
            ExportDestination::Ftp {
                destination_id: "f".into()
            }
        );
        let s: ExportScope =
            serde_json::from_value(json!({"kind": "selected", "captureId": "c"})).unwrap();
        assert_eq!(s.memory_id(), "selected");
        assert_eq!(ExportScope::from_memory_id("rated4"), ExportScope::Rated { min: 4 });
        let o = ExportOptions::from(&LibOptions::default());
        let v = serde_json::to_value(&o).unwrap();
        assert_eq!(v["namingPattern"], "{orig}");
        assert_eq!(v["layout"], "flat");
        assert_eq!(v["rawOutput"], "original");
        assert_eq!(v["maxLongEdge"], Value::Null);
    }

    #[test]
    fn connect_progress_steps() {
        let mut p = ConnectProgress::new(TransportKind::Usb);
        p.advance(ConnectStep::Identify);
        let states: Vec<_> = p.steps.iter().map(|s| s.state).collect();
        assert_eq!(
            states,
            [
                StepState::Done,
                StepState::Done,
                StepState::Running,
                StepState::Pending,
                StepState::Pending
            ]
        );
        p.fail("nope".into());
        assert_eq!(p.steps[2].state, StepState::Failed);
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["steps"][0]["step"], "link");
        assert_eq!(v["failure"], "nope");
    }

    #[test]
    fn statuses_and_properties() {
        let v = serde_json::to_value(ShootStatus::from(&TetherStatus::Disconnected("x".into())))
            .unwrap();
        assert_eq!(v, json!({"kind": "disconnected", "reason": "x"}));
        assert_eq!(ptp_json(&PtpValue::UInt16(400)), json!(400));
        assert_eq!(ptp_json(&PtpValue::String("a".into())), json!("a"));
        let u = UsbAuthorization {
            can_send_ptp: true,
            is_denied: false,
            summary: String::new(),
        };
        assert_eq!(serde_json::to_value(u).unwrap()["canSendPTP"], true);
    }
}
