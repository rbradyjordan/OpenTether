//! Errors the session layer and `AppCore` report. Serialised as their
//! message, so the Tauri shell can hand them to the UI as they are.

use serde::{Serialize, Serializer};
use tether_ptp::PtpError;

/// Connect failures worded for the user (`ConnectError` in the iOS app).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ConnectError {
    #[error("The camera is no longer on the USB bus.")]
    DeviceGone,
    #[error("\"{0}\" is not a usable address.")]
    BadHost(String),
    #[error("Connection cancelled.")]
    Cancelled,
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Ptp(#[from] PtpError),
    #[error(transparent)]
    Library(#[from] tether_library::Error),
    #[error(transparent)]
    Connect(#[from] ConnectError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    /// A relative path was absolute, escaped the storage root, or was empty.
    #[error("invalid path: {0}")]
    InvalidPath(String),
    #[error("{0} not found")]
    NotFound(String),
    /// Anything else, already worded for the user.
    #[error("{0}")]
    Message(String),
}

impl Error {
    pub fn msg(s: impl Into<String>) -> Self {
        Self::Message(s.into())
    }
}

impl Serialize for Error {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

/// Locks a std mutex, recovering the data if a panicking thread poisoned it.
pub(crate) fn lock<T>(m: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}
