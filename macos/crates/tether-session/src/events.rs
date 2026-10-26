//! What `AppCore` tells the UI: one broadcast of [`AppEvent`]s, plus the
//! serialisable views (DTOs) its methods return. Everything serialises
//! camelCase with RFC 3339 dates, independent of the Swift-compatible JSON
//! the store keeps.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tether_library::delivery::{ExportJob, ItemState};
use tether_library::library::Collection;
use tether_library::store::SessionCounts;
use tether_library::{
    CaptureFlag, CaptureItem, CaptureState, ColorLabel, ExposureSummary, MediaKind, RoutingRules,
    SessionStatus, ShootSession,
};
use tether_net::{DiscoveredCamera, FtpServerConfig};
use tether_ptp::device::PropertyForm;
use tether_ptp::ptp::PtpValue;
use tether_ptp::{PropertyDescriptor, TetherProperty};
use tether_types::{CameraIdentity, CaptureDestination, TransportKind};

use crate::diagnostics::DiagnosticReport;
use crate::session::{ConnectStep, ReconnectStrategy, TetherStatus};

/// A capture as the UI sees it. Images are served by path
/// (`AppCore::image_path`); `has_thumbnail` / `has_preview` say which exist.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureDto {
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
    /// "announced" | "downloading" | "ready" | "failed".
    pub state: String,
    /// 0…1 while downloading.
    pub progress: Option<f64>,
    pub error: Option<String>,
    pub pair_key: String,
    pub source: TransportKind,
    pub look_id: Option<String>,
    pub exposure: Option<ExposureSummary>,
    pub camera_id: Option<String>,
    pub has_thumbnail: bool,
    pub has_preview: bool,
}

impl From<&CaptureItem> for CaptureDto {
    fn from(c: &CaptureItem) -> Self {
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
            state: c.state.key().into(),
            progress: c.state.progress(),
            error: match &c.state {
                CaptureState::Failed(e) => Some(e.clone()),
                _ => None,
            },
            pair_key: c.pair_key.clone(),
            source: c.source,
            look_id: c.look_id.clone(),
            exposure: c.exposure.clone(),
            camera_id: c.camera_id.clone(),
            has_thumbnail: c.thumbnail_relative_path.is_some(),
            has_preview: c.preview_relative_path().is_some(),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CountsDto {
    pub total: i64,
    pub ready: i64,
    pub picks: i64,
    pub rejects: i64,
    pub rated: i64,
    pub failed: i64,
}

impl From<SessionCounts> for CountsDto {
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
pub struct SessionDto {
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
    pub is_demo: bool,
    pub counts: CountsDto,
}

impl SessionDto {
    pub fn new(s: &ShootSession, counts: CountsDto) -> Self {
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
            routing: s.routing.clone(),
            look_id: s.look_id.clone(),
            look_strength: s.look_strength,
            show_newest_capture: s.show_newest_capture,
            workflow_tag: s.workflow_tag.clone(),
            capture_count: s.capture_count,
            is_demo: s.workflow_tag.as_deref() == Some(crate::demo::TAG),
            counts,
        }
    }
}

/// One camera setting with its choices, by index (raw PTP values stay in
/// the core; the UI sets a property by choice index or number).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PropertyDto {
    pub property: TetherProperty,
    pub name: String,
    pub display: String,
    pub is_writable: bool,
    pub choices: Vec<String>,
    pub current_index: Option<usize>,
    pub range: Option<RangeDto>,
    /// The raw value as a number when it is one.
    pub value: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct RangeDto {
    pub min: f64,
    pub max: f64,
    pub step: f64,
}

impl From<&PropertyDescriptor> for PropertyDto {
    fn from(p: &PropertyDescriptor) -> Self {
        Self {
            property: p.property,
            name: p.property.display_name().into(),
            display: p.display.clone(),
            is_writable: p.is_writable,
            choices: p.choices().iter().map(|c| c.display.clone()).collect(),
            current_index: p.current_choice_index(),
            range: match p.form {
                PropertyForm::Range { min, max, step } => Some(RangeDto { min, max, step }),
                _ => None,
            },
            value: p.raw.int_value(),
        }
    }
}

/// How the UI sets a property.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum PropertyInput {
    /// Index into `PropertyDto::choices`.
    Choice(usize),
    /// A number for range properties, encoded in the current value's type.
    Number(i64),
}

impl PropertyInput {
    pub fn to_value(&self, p: &PropertyDescriptor) -> Option<PtpValue> {
        match self {
            Self::Choice(i) => p.choices().get(*i).map(|c| c.raw.clone()),
            Self::Number(n) => Some(PtpValue::make(p.raw.data_type(), *n)),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportJobDto {
    pub id: String,
    pub session_id: String,
    /// "photos" | "files" | "share" | "ftp" | "folder".
    pub destination: String,
    pub destination_name: String,
    pub destination_id: Option<String>,
    /// "queued" | "running" | "paused" | "completed" | "failed".
    pub status: String,
    pub error: Option<String>,
    pub progress: f64,
    pub total: usize,
    pub done: usize,
    pub failed: usize,
    pub created_at: DateTime<Utc>,
    pub attempts: i64,
}

impl From<&ExportJob> for ExportJobDto {
    fn from(j: &ExportJob) -> Self {
        use tether_library::delivery::{ExportDestination, ExportStatus};
        let real: Vec<_> = j.items.iter().filter(|i| !i.is_companion).collect();
        Self {
            id: j.id.clone(),
            session_id: j.session_id.clone(),
            destination: j.destination.key().into(),
            destination_name: j.destination.display_name().into(),
            destination_id: match &j.destination {
                ExportDestination::Ftp { destination_id }
                | ExportDestination::Folder { destination_id } => Some(destination_id.clone()),
                _ => None,
            },
            status: j.status.key().into(),
            error: match &j.status {
                ExportStatus::Failed(e) => Some(e.clone()),
                _ => None,
            },
            progress: j.progress(),
            total: real.len(),
            done: real
                .iter()
                .filter(|i| matches!(i.state, ItemState::Done(_) | ItemState::Skipped(_)))
                .count(),
            failed: real.iter().filter(|i| i.is_failed()).count(),
            created_at: j.created_at,
            attempts: j.attempts,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CollectionDto {
    pub id: String,
    pub name: String,
    /// "manual" | "smart".
    pub kind: String,
    pub symbol: String,
    pub tint: ColorLabel,
    pub is_pinned: bool,
    pub is_built_in: bool,
    pub sort_order: i64,
    pub count: i64,
    pub rule: Option<tether_library::library::CaptureFilter>,
}

impl CollectionDto {
    pub fn new(c: &Collection, count: i64) -> Self {
        Self {
            id: c.id.clone(),
            name: c.name.clone(),
            kind: c.kind.raw().into(),
            symbol: c.symbol.clone(),
            tint: c.tint,
            is_pinned: c.is_pinned,
            is_built_in: c.is_built_in,
            sort_order: c.sort_order,
            count,
            rule: c.rule.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsbDeviceDto {
    pub id: String,
    pub name: String,
    pub usb_vendor_id: i32,
    pub usb_product_id: i32,
    pub serial_number: Option<String>,
    pub vendor_guess: tether_types::CameraVendor,
    pub vendor_name: String,
    pub has_open_session: bool,
}

impl From<&tether_ptp::usb::UsbCameraCandidate> for UsbDeviceDto {
    fn from(c: &tether_ptp::usb::UsbCameraCandidate) -> Self {
        Self {
            id: c.id.clone(),
            name: c.name.clone(),
            usb_vendor_id: c.usb_vendor_id,
            usb_product_id: c.usb_product_id,
            serial_number: c.serial_number.clone(),
            vendor_guess: c.vendor_guess,
            vendor_name: c.vendor_guess.display_name().into(),
            has_open_session: c.has_open_session,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsbAuthorizationDto {
    /// "notDetermined" | "granted" | "denied" | "notRequired".
    pub control: String,
    pub contents: String,
    pub can_send_ptp: bool,
    pub is_denied: bool,
    pub summary: String,
}

impl From<tether_ptp::usb::UsbAuthorizationState> for UsbAuthorizationDto {
    fn from(a: tether_ptp::usb::UsbAuthorizationState) -> Self {
        Self {
            control: a.control.raw().into(),
            contents: a.contents.raw().into(),
            can_send_ptp: a.can_send_ptp(),
            is_denied: a.is_denied(),
            summary: a.summary(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FtpReceiverStatus {
    pub is_running: bool,
    pub port: Option<u16>,
    pub addresses: Vec<String>,
    pub primary_address: Option<String>,
    pub clients: usize,
    pub username: String,
    pub password: String,
    pub last_error: Option<String>,
}

impl FtpReceiverStatus {
    pub fn configured_port_default() -> u16 {
        FtpServerConfig::DEFAULT_PORT
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FtpFileDto {
    pub name: String,
    pub bytes: u64,
    pub from: String,
    pub at: DateTime<Utc>,
    pub duration_ms: u64,
}

/// The live shoot as the shoot screen needs it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShootStateDto {
    pub session: SessionDto,
    pub identity: Option<CameraIdentity>,
    pub camera_name: String,
    pub transport_name: String,
    pub status: TetherStatus,
    pub status_text: String,
    pub items: Vec<CaptureDto>,
    pub properties: Vec<PropertyDto>,
    pub selected_item_id: Option<String>,
    pub live_view_active: bool,
    pub downloads_in_flight: usize,
    pub can_capture: bool,
    pub can_live_view: bool,
    pub can_touch_focus: bool,
    pub can_control_properties: bool,
    pub is_import_only: bool,
    pub reconnect: ReconnectStrategy,
    pub reconnect_title: String,
    pub reconnect_detail: String,
    pub is_reconnecting: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToastKind {
    Info,
    Success,
    Warning,
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum AppEvent {
    /// The live link changed state.
    ConnectionStatus {
        session_id: String,
        status: TetherStatus,
        text: String,
    },
    /// A connect attempt moved on (or failed).
    ConnectProgress {
        step: Option<ConnectStep>,
        error: Option<String>,
    },
    ShootStarted {
        shoot: Box<ShootStateDto>,
    },
    ShootEnded {
        session_id: String,
    },
    Reconnect {
        reconnecting: bool,
        strategy: ReconnectStrategy,
        title: String,
        detail: String,
        error: Option<String>,
    },
    DiscoveryUpdated {
        cameras: Vec<DiscoveredCamera>,
    },
    UsbDevices {
        devices: Vec<UsbDeviceDto>,
    },
    UsbAuthorization {
        authorization: UsbAuthorizationDto,
    },
    /// A new frame is ready; fetch it with `AppCore::live_view_frame`.
    LiveViewFrame {
        session_id: String,
        sequence: u64,
        width: Option<u32>,
        height: Option<u32>,
    },
    LiveViewState {
        active: bool,
    },
    CaptureAdded {
        capture: Box<CaptureDto>,
    },
    CaptureUpdated {
        capture: Box<CaptureDto>,
    },
    CaptureRemoved {
        id: String,
    },
    DownloadProgress {
        capture_id: String,
        received: i64,
        total: Option<i64>,
        in_flight: usize,
    },
    Properties {
        properties: Vec<PropertyDto>,
    },
    Selection {
        capture_id: Option<String>,
    },
    ExportProgress {
        job: ExportJobDto,
    },
    ExportFinished {
        job: ExportJobDto,
    },
    FtpServer {
        status: FtpReceiverStatus,
    },
    FtpFileReceived {
        file: FtpFileDto,
    },
    Toast {
        text: String,
        kind: ToastKind,
    },
    UndoState {
        undo_title: Option<String>,
        redo_title: Option<String>,
    },
    /// Review state of these captures changed (library edits, automations).
    LibraryChanged {
        ids: Vec<String>,
    },
    SessionsChanged,
    Diagnostics {
        report: DiagnosticReport,
        finished: bool,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_serialise_camel_case() {
        let e = AppEvent::LiveViewFrame {
            session_id: "s".into(),
            sequence: 3,
            width: None,
            height: None,
        };
        let v = serde_json::to_value(&e).unwrap();
        assert_eq!(v["type"], "liveViewFrame");
        assert_eq!(v["sessionId"], "s");
        assert_eq!(v["sequence"], 3);
        let t = serde_json::to_value(AppEvent::ConnectionStatus {
            session_id: "s".into(),
            status: TetherStatus::Disconnected("x".into()),
            text: "x".into(),
        })
        .unwrap();
        assert_eq!(t["status"]["state"], "disconnected");
        assert_eq!(t["status"]["reason"], "x");
        let c = CaptureItem::new("s", 1, 1, "A.JPG", MediaKind::Jpeg, 3, TransportKind::Usb);
        let d = serde_json::to_value(CaptureDto::from(&c)).unwrap();
        assert_eq!(d["sessionId"], "s");
        assert_eq!(d["colorLabel"], "none");
        assert_eq!(d["state"], "announced");
    }
}
