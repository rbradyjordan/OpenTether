//! The capture data model (`Capture/CaptureItem.swift`): frames, shoots and
//! export routing. Serialised field names match the Swift `Codable` output.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use tether_types::{CameraIdentity, CaptureDestination, TransportKind};

use crate::swift_json::{self, Empty, Unnamed};
use crate::util;

/// Review metadata that round-trips to the gallery layer later.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, Default,
)]
#[serde(rename_all = "lowercase")]
pub enum CaptureFlag {
    #[default]
    None,
    Pick,
    Reject,
}

impl CaptureFlag {
    pub const ALL: [CaptureFlag; 3] = [Self::None, Self::Pick, Self::Reject];

    pub fn raw(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Pick => "pick",
            Self::Reject => "reject",
        }
    }

    pub fn from_raw(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|f| f.raw() == s)
    }
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, Default,
)]
#[serde(rename_all = "lowercase")]
pub enum ColorLabel {
    #[default]
    None,
    Red,
    Yellow,
    Green,
    Blue,
    Purple,
}

impl ColorLabel {
    pub const ALL: [ColorLabel; 6] = [
        Self::None,
        Self::Red,
        Self::Yellow,
        Self::Green,
        Self::Blue,
        Self::Purple,
    ];

    pub fn raw(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Red => "red",
            Self::Yellow => "yellow",
            Self::Green => "green",
            Self::Blue => "blue",
            Self::Purple => "purple",
        }
    }

    pub fn from_raw(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|c| c.raw() == s)
    }
}

/// What a file is, by format and extension (`PTPDataSets.swift`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum MediaKind {
    #[serde(rename = "jpeg")]
    Jpeg,
    #[serde(rename = "heif")]
    Heif,
    #[serde(rename = "raw")]
    Raw,
    #[serde(rename = "jpegXL")]
    JpegXl,
    #[serde(rename = "video")]
    Video,
    #[serde(rename = "other")]
    Other,
}

impl MediaKind {
    pub const ALL: [MediaKind; 6] = [
        Self::Jpeg,
        Self::Heif,
        Self::Raw,
        Self::JpegXl,
        Self::Video,
        Self::Other,
    ];

    /// Every RAW extension recognised (lowercase).
    pub const RAW_EXTENSIONS: [&'static str; 27] = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "sr2", "raf", "orf", "rw2", "dng", "3fr", "fff",
        "pef", "x3f",
        "iiq", // Samsung, Leica, Epson, Leaf/Mamiya, Minolta, Kodak, GoPro, Phase One
        "srw", "rwl", "erf", "mos", "mef", "mrw", "kdc", "dcr", "gpr", "cap", "eip",
    ];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Jpeg => "jpeg",
            Self::Heif => "heif",
            Self::Raw => "raw",
            Self::JpegXl => "jpegXL",
            Self::Video => "video",
            Self::Other => "other",
        }
    }

    pub fn from_raw(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.raw() == s)
    }

    pub fn is_still(self) -> bool {
        !matches!(self, Self::Video | Self::Other)
    }

    /// Kind from a file name alone (what iOS does for an object with an
    /// undefined PTP format: FTP pushes, Files imports).
    pub fn from_filename(filename: &str) -> Self {
        let ext = util::path_extension(filename).to_lowercase();
        Self::from_extension(&ext)
    }

    pub fn from_extension(ext: &str) -> Self {
        let ext = ext.to_lowercase();
        match ext.as_str() {
            "heic" | "hif" | "heif" => Self::Heif,
            "jxl" => Self::JpegXl,
            "mp4" | "mov" | "avi" | "mpg" => Self::Video,
            "jpg" | "jpeg" => Self::Jpeg,
            e if Self::RAW_EXTENSIONS.contains(&e) => Self::Raw,
            _ => Self::Other,
        }
    }
}

/// Where a capture is in its download.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(into = "StateRepr", from = "StateRepr")]
pub enum CaptureState {
    Announced,
    Downloading { received: i64, total: Option<i64> },
    Ready,
    Failed(String),
}

impl CaptureState {
    pub fn is_ready(&self) -> bool {
        matches!(self, Self::Ready)
    }

    pub fn is_failed(&self) -> bool {
        matches!(self, Self::Failed(_))
    }

    pub fn progress(&self) -> Option<f64> {
        match self {
            Self::Downloading {
                received,
                total: Some(t),
            } if *t > 0 => Some(*received as f64 / *t as f64),
            _ => None,
        }
    }

    /// The `state` column value.
    pub fn key(&self) -> &'static str {
        match self {
            Self::Announced => "announced",
            Self::Downloading { .. } => "downloading",
            Self::Ready => "ready",
            Self::Failed(_) => "failed",
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
enum StateRepr {
    Announced(Empty),
    Downloading {
        received: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        total: Option<i64>,
    },
    Ready(Empty),
    Failed(Unnamed<String>),
}

impl From<CaptureState> for StateRepr {
    fn from(s: CaptureState) -> Self {
        match s {
            CaptureState::Announced => Self::Announced(Empty {}),
            CaptureState::Downloading { received, total } => Self::Downloading { received, total },
            CaptureState::Ready => Self::Ready(Empty {}),
            CaptureState::Failed(m) => Self::Failed(Unnamed { value: m }),
        }
    }
}

impl From<StateRepr> for CaptureState {
    fn from(s: StateRepr) -> Self {
        match s {
            StateRepr::Announced(_) => Self::Announced,
            StateRepr::Downloading { received, total } => Self::Downloading { received, total },
            StateRepr::Ready(_) => Self::Ready,
            StateRepr::Failed(u) => Self::Failed(u.value),
        }
    }
}

/// One frame received from the camera (or pushed over FTP). RAW+JPEG pairs
/// are two items sharing a `pair_key`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CaptureItem {
    pub id: String,
    #[serde(rename = "sessionID")]
    pub session_id: String,
    pub sequence: i64,
    pub handle: u32,
    pub filename: String,
    pub kind: MediaKind,
    pub bytes: i64,
    pub width: i64,
    pub height: i64,
    #[serde(rename = "capturedAt", with = "swift_json::date")]
    pub captured_at: DateTime<Utc>,
    #[serde(rename = "receivedAt", with = "swift_json::date")]
    pub received_at: DateTime<Utc>,
    /// Relative path under the session directory (never absolute; see §7 of the spec).
    #[serde(
        rename = "relativePath",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub relative_path: Option<String>,
    /// JPEG proxy for RAW files (camera-embedded preview or our own render).
    #[serde(
        rename = "proxyRelativePath",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub proxy_relative_path: Option<String>,
    #[serde(
        rename = "thumbnailRelativePath",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub thumbnail_relative_path: Option<String>,
    pub rating: i64,
    pub flag: CaptureFlag,
    #[serde(rename = "colorLabel")]
    pub color_label: ColorLabel,
    pub state: CaptureState,
    #[serde(rename = "pairKey")]
    pub pair_key: String,
    pub source: TransportKind,
    #[serde(rename = "lookID", default, skip_serializing_if = "Option::is_none")]
    pub look_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exposure: Option<ExposureSummary>,
    /// The camera that made it (`CameraIdentity::id`); lets the library filter by body.
    #[serde(rename = "cameraID", default, skip_serializing_if = "Option::is_none")]
    pub camera_id: Option<String>,
}

impl CaptureItem {
    /// A freshly announced capture with the defaults iOS uses (new UUID,
    /// now for both dates, unrated, pair key from the file name).
    pub fn new(
        session_id: impl Into<String>,
        sequence: i64,
        handle: u32,
        filename: impl Into<String>,
        kind: MediaKind,
        bytes: i64,
        source: TransportKind,
    ) -> Self {
        let filename = filename.into();
        let now = Utc::now();
        Self {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            session_id: session_id.into(),
            sequence,
            handle,
            pair_key: Self::pair_key_for(&filename),
            filename,
            kind,
            bytes,
            width: 0,
            height: 0,
            captured_at: now,
            received_at: now,
            relative_path: None,
            proxy_relative_path: None,
            thumbnail_relative_path: None,
            rating: 0,
            flag: CaptureFlag::None,
            color_label: ColorLabel::None,
            state: CaptureState::Announced,
            source,
            look_id: None,
            exposure: None,
            camera_id: None,
        }
    }

    /// `IMG_0001.CR3` and `IMG_0001.JPG` share `IMG_0001`.
    pub fn pair_key_for(filename: &str) -> String {
        let base = util::delete_path_extension(filename);
        if base.is_empty() {
            filename.to_string()
        } else {
            base.to_uppercase()
        }
    }

    /// Sets the rating clamped to 0…5, as the Swift initialiser does.
    pub fn set_rating(&mut self, stars: i64) {
        self.rating = stars.clamp(0, 5);
    }

    pub fn is_raw(&self) -> bool {
        self.kind == MediaKind::Raw
    }

    pub fn display_name(&self) -> &str {
        &self.filename
    }

    /// The file to show: a JPEG proxy for RAW when we have one, else the original.
    pub fn preview_relative_path(&self) -> Option<&str> {
        self.proxy_relative_path
            .as_deref()
            .or(if self.kind == MediaKind::Raw {
                None
            } else {
                self.relative_path.as_deref()
            })
    }
}

/// Exposure read from the camera at capture time (not EXIF; that comes later).
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExposureSummary {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aperture: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shutter: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub iso: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compensation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub white_balance: Option<String>,
}

impl ExposureSummary {
    /// From `(property raw value, display)` pairs, e.g. `("iso", "400")`;
    /// the property names are `TetherProperty` raw values.
    pub fn from_properties<'a>(props: impl IntoIterator<Item = (&'a str, &'a str)>) -> Self {
        let mut out = Self::default();
        for (p, display) in props {
            let slot = match p {
                "aperture" => &mut out.aperture,
                "shutterSpeed" => &mut out.shutter,
                "iso" => &mut out.iso,
                "exposureCompensation" => &mut out.compensation,
                "whiteBalance" => &mut out.white_balance,
                _ => continue,
            };
            if slot.is_none() {
                *slot = Some(display.to_string());
            }
        }
        out
    }

    /// `1/250  ƒ/2.8  ISO 400  +1 EV`.
    pub fn line(&self) -> String {
        let mut parts: Vec<String> = Vec::new();
        parts.extend(self.shutter.clone());
        parts.extend(self.aperture.clone());
        parts.extend(self.iso.as_ref().map(|i| format!("ISO {i}")));
        parts.extend(
            self.compensation
                .as_ref()
                .filter(|c| c.as_str() != "0")
                .map(|c| format!("{c} EV")),
        );
        parts.join("  ")
    }
}

/// A shoot's lifecycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SessionStatus {
    #[default]
    Active,
    Interrupted,
    Ended,
}

impl SessionStatus {
    pub fn raw(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Interrupted => "interrupted",
            Self::Ended => "ended",
        }
    }
}

/// A shoot. Created before connecting; survives relaunch for mid-shoot recovery.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShootSession {
    pub id: String,
    pub name: String,
    #[serde(rename = "createdAt", with = "swift_json::date")]
    pub created_at: DateTime<Utc>,
    #[serde(
        rename = "endedAt",
        with = "swift_json::opt_date",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub ended_at: Option<DateTime<Utc>>,
    pub status: SessionStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera: Option<CameraIdentity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transport: Option<TransportKind>,
    /// For PTP/IP reconnects after backgrounding.
    #[serde(rename = "lastHost", default, skip_serializing_if = "Option::is_none")]
    pub last_host: Option<String>,
    pub destination: CaptureDestination,
    pub routing: RoutingRules,
    #[serde(rename = "lookID", default, skip_serializing_if = "Option::is_none")]
    pub look_id: Option<String>,
    #[serde(rename = "lookStrength")]
    pub look_strength: f64,
    #[serde(rename = "showNewestCapture")]
    pub show_newest_capture: bool,
    /// Optional reference to the booking/client in the workflow platform.
    #[serde(
        rename = "workflowTag",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub workflow_tag: Option<String>,
    #[serde(rename = "captureCount")]
    pub capture_count: i64,
}

impl ShootSession {
    /// A new active shoot with iOS's defaults (card + host, full-strength
    /// look slot, newest capture shown).
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            name: name.into(),
            created_at: Utc::now(),
            ended_at: None,
            status: SessionStatus::Active,
            camera: None,
            transport: None,
            last_host: None,
            destination: CaptureDestination::Both,
            routing: RoutingRules::default(),
            look_id: None,
            look_strength: 1.0,
            show_newest_capture: true,
            workflow_tag: None,
            capture_count: 0,
        }
    }

    /// Directory name under the storage root. Validated: no separators.
    pub fn directory_name(&self) -> String {
        self.id.replace('/', "_")
    }
}

/// An export target for one media kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RoutingTarget {
    Photos,
    Files,
    Ftp,
    None,
}

impl RoutingTarget {
    pub const ALL: [RoutingTarget; 4] = [Self::Photos, Self::Files, Self::Ftp, Self::None];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Photos => "photos",
            Self::Files => "files",
            Self::Ftp => "ftp",
            Self::None => "none",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Photos => "Photos",
            Self::Files => "Files (on this Mac)",
            Self::Ftp => "FTP server",
            Self::None => "Keep in session only",
        }
    }
}

/// Sessions saved when a cloud target existed open as Files.
impl<'de> Deserialize<'de> for RoutingTarget {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(d)?;
        Ok(Self::ALL
            .into_iter()
            .find(|t| t.raw() == raw)
            .unwrap_or(Self::Files))
    }
}

/// Where each media kind goes on export (JPEG → Photos, RAW → Files by default).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct RoutingRules {
    pub jpeg: RoutingTarget,
    pub raw: RoutingTarget,
    pub video: RoutingTarget,
    #[serde(rename = "autoExportPicks")]
    pub auto_export_picks: bool,
    #[serde(
        rename = "ftpDestinationID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub ftp_destination_id: Option<String>,
    /// Hot folder: every frame (RAW and JPEG, with its sidecar) is copied into
    /// this saved folder as soon as it lands, e.g. a Capture One session's
    /// Capture folder or a Lightroom Auto Import folder on a share.
    #[serde(
        rename = "liveFolderID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub live_folder_id: Option<String>,
}

impl Default for RoutingRules {
    fn default() -> Self {
        Self {
            jpeg: RoutingTarget::Photos,
            raw: RoutingTarget::Files,
            video: RoutingTarget::Files,
            auto_export_picks: false,
            ftp_destination_id: None,
            live_folder_id: None,
        }
    }
}

impl RoutingRules {
    pub fn target(&self, kind: MediaKind) -> RoutingTarget {
        match kind {
            MediaKind::Jpeg | MediaKind::Heif | MediaKind::JpegXl => self.jpeg,
            MediaKind::Raw => self.raw,
            MediaKind::Video => self.video,
            MediaKind::Other => RoutingTarget::Files,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_codes_like_swift() {
        let j = serde_json::to_string(&CaptureState::Downloading {
            received: 10,
            total: Some(100),
        })
        .unwrap();
        assert_eq!(j, r#"{"downloading":{"received":10,"total":100}}"#);
        assert_eq!(
            serde_json::to_string(&CaptureState::Ready).unwrap(),
            r#"{"ready":{}}"#
        );
        assert_eq!(
            serde_json::to_string(&CaptureState::Failed("x".into())).unwrap(),
            r#"{"failed":{"_0":"x"}}"#
        );
        let back: CaptureState = serde_json::from_str(r#"{"downloading":{"received":1}}"#).unwrap();
        assert_eq!(
            back,
            CaptureState::Downloading {
                received: 1,
                total: None
            }
        );
    }

    #[test]
    fn decodes_a_capture_written_by_ios() {
        let json = r#"{"id":"A","sessionID":"S","sequence":1,"handle":16,"filename":"IMG_0001.CR3","kind":"raw","bytes":100,
            "width":0,"height":0,"capturedAt":782000000.5,"receivedAt":782000001,"rating":4,"flag":"pick","colorLabel":"blue",
            "state":{"ready":{}},"pairKey":"IMG_0001","source":"usb","cameraID":"canon-1"}"#;
        let c: CaptureItem = serde_json::from_str(json).unwrap();
        assert_eq!(c.session_id, "S");
        assert_eq!(c.flag, CaptureFlag::Pick);
        assert_eq!(c.camera_id.as_deref(), Some("canon-1"));
        assert!(c.relative_path.is_none());
        let again: CaptureItem = serde_json::from_str(&serde_json::to_string(&c).unwrap()).unwrap();
        assert_eq!(again, c);
        assert!(!serde_json::to_string(&c).unwrap().contains("relativePath"));
    }

    #[test]
    fn pair_keys_and_kinds() {
        assert_eq!(CaptureItem::pair_key_for("img_0001.cr3"), "IMG_0001");
        assert_eq!(MediaKind::from_filename("A.NEF"), MediaKind::Raw);
        assert_eq!(MediaKind::from_filename("clip.MOV"), MediaKind::Video);
        assert_eq!(MediaKind::from_filename("x.json"), MediaKind::Other);
        let r: RoutingTarget = serde_json::from_str("\"cloud\"").unwrap();
        assert_eq!(r, RoutingTarget::Files);
        let e = ExposureSummary::from_properties([
            ("shutterSpeed", "1/250"),
            ("iso", "400"),
            ("exposureCompensation", "0"),
        ]);
        assert_eq!(e.line(), "1/250  ISO 400");
    }
}
