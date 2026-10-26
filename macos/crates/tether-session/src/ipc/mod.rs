//! The UI contract (`docs/IPC.md`) on top of [`AppCore`]: one method per
//! command with the contract's argument and result shapes, the error
//! mapping to `{ code, message }`, the translation of [`AppEvent`]s into
//! the contract's events, and the `tether://` image responses.
//!
//! The Tauri shell holds an [`Ipc`] and forwards every command to it; it
//! adds only what needs the window system (dialogs, Finder, bookmarks).
//! Keeping the contract here means it is tested without a webview.
//!
//! [`AppEvent`]: crate::AppEvent

mod commands;
pub mod dto;
mod events;
pub mod images;

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use serde_json::Value;
use tokio::task::AbortHandle;

use crate::app_core::AppCore;
use crate::error::{lock, ConnectError, Error};

pub use dto::*;
pub use images::ImageResponse;

/// Every command's error: a stable `code` and one user-facing sentence.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IpcError {
    pub code: String,
    pub message: String,
}

impl IpcError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn not_found(what: &str) -> Self {
        Self::new("notFound", format!("{what} not found."))
    }

    pub fn no_shoot() -> Self {
        Self::new("noShoot", "No session is open.")
    }

    pub fn nothing_selected() -> Self {
        Self::new("nothingSelected", "Nothing is selected.")
    }

    pub fn unsupported(message: impl Into<String>) -> Self {
        Self::new("unsupported", message)
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::new("internal", message)
    }

    /// For connect paths: anything that is not more specific is a
    /// `connectFailed`.
    pub fn connect(e: Error) -> Self {
        let mut out = Self::from(e);
        if out.code == "internal" || out.code == "io" || out.code == "notReady" {
            let lower = out.message.to_lowercase();
            out.code = if lower.contains("in use")
                || lower.contains("another app")
                || lower.contains("busy")
                || lower.contains("exclusive")
            {
                "busy".into()
            } else {
                "connectFailed".into()
            };
        }
        out
    }
}

impl std::fmt::Display for IpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for IpcError {}

impl From<Error> for IpcError {
    fn from(e: Error) -> Self {
        use tether_library::library::LibraryError;
        use tether_ptp::PtpError;
        let message = e.to_string();
        let code = match &e {
            Error::NotFound(_) => "notFound",
            Error::Io(_) => "io",
            Error::InvalidPath(_) => "notFound",
            Error::Connect(ConnectError::DeviceGone) => "deviceGone",
            Error::Connect(ConnectError::Cancelled) => "cancelled",
            Error::Connect(ConnectError::BadHost(_)) => "connectFailed",
            Error::Ptp(PtpError::Cancelled) => "cancelled",
            Error::Ptp(PtpError::Unsupported(_)) => "unsupported",
            Error::Ptp(PtpError::SessionNotOpen | PtpError::NotConnected) => "notReady",
            Error::Ptp(_) => "internal",
            Error::Library(tether_library::Error::Library(LibraryError::NothingSelected)) => {
                "nothingSelected"
            }
            Error::Library(tether_library::Error::Io(_)) => "io",
            Error::Message(m) if m == "No shoot is open." => "noShoot",
            Error::Message(_) | Error::Library(_) => "internal",
        };
        let message = if code == "noShoot" {
            "No session is open.".to_string()
        } else {
            message
        };
        Self::new(code, message)
    }
}

impl From<tether_library::Error> for IpcError {
    fn from(e: tether_library::Error) -> Self {
        Error::from(e).into()
    }
}

impl From<std::io::Error> for IpcError {
    fn from(e: std::io::Error) -> Self {
        Self::new("io", e.to_string())
    }
}

pub type IpcResult<T> = std::result::Result<T, IpcError>;

/// Where events go (the shell's `app.emit`).
pub type EventSink = Arc<dyn Fn(&str, Value) + Send + Sync>;

/// One connect attempt in progress.
pub(crate) struct Attempt {
    pub progress: ConnectProgress,
    pub abort: Option<AbortHandle>,
    pub open: bool,
}

#[derive(Default)]
pub(crate) struct State {
    pub sink: Option<EventSink>,
    /// The newest live-view JPEGs by sequence (last three).
    pub live_frames: VecDeque<(u64, Arc<Vec<u8>>)>,
    pub attempt: Option<Attempt>,
    /// Sessions whose "use last time's look" banner was answered.
    pub offers_answered: HashSet<String>,
    pub discovery_running: bool,
    pub usb_started: bool,
    pub local_network: Option<PermissionState>,
    /// The diagnostic run in progress: (id, wired).
    pub diagnostic: Option<(String, bool)>,
    /// Rendered look variants: key → JPEG, oldest first.
    pub look_cache: VecDeque<(String, Arc<Vec<u8>>)>,
    /// Throttles: last emission per entity.
    pub last_progress: HashMap<String, std::time::Instant>,
    pub last_live_frame: Option<std::time::Instant>,
    pub library_pending: bool,
}

/// The contract adapter. Cheap to clone.
#[derive(Clone)]
pub struct Ipc {
    pub(crate) core: AppCore,
    pub(crate) state: Arc<Mutex<State>>,
}

impl std::fmt::Debug for Ipc {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Ipc").field("core", &self.core).finish()
    }
}

impl Ipc {
    pub fn new(core: AppCore) -> Self {
        Self {
            core,
            state: Arc::new(Mutex::new(State::default())),
        }
    }

    pub fn core(&self) -> &AppCore {
        &self.core
    }

    pub(crate) fn state(&self) -> std::sync::MutexGuard<'_, State> {
        lock(&self.state)
    }

    /// Emit one contract event (no-op until [`Ipc::start_events`]).
    pub fn emit<T: Serialize>(&self, name: &str, payload: &T) {
        let sink = self.state().sink.clone();
        if let (Some(sink), Ok(v)) = (sink, serde_json::to_value(payload)) {
            sink(name, v);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_map_to_codes() {
        assert_eq!(
            IpcError::from(Error::NotFound("Session x".into())).code,
            "notFound"
        );
        assert_eq!(
            IpcError::from(Error::msg("No shoot is open.")).code,
            "noShoot"
        );
        assert_eq!(
            IpcError::from(Error::Connect(ConnectError::Cancelled)).code,
            "cancelled"
        );
        let e = IpcError::connect(Error::msg("The camera is in use by another app."));
        assert_eq!(e.code, "busy");
        let e = IpcError::connect(Error::msg("Nothing answered."));
        assert_eq!(e.code, "connectFailed");
        let v = serde_json::to_value(IpcError::new("io", "x")).unwrap();
        assert_eq!(v, serde_json::json!({"code": "io", "message": "x"}));
    }
}
