//! Network side of Open Tether: camera discovery on the local network
//! (SSDP for Sony, Bonjour for Canon/Nikon/…, the Fujifilm UDP announce with
//! its TCP dial-back, and HTTP probes of the fixed addresses Ricoh GR, GoPro
//! and OSC 360° cameras use), the FTP server cameras push photos to, and the
//! FTP/FTPS client that uploads exports to the user's own server.
//!
//! Ported from `TetherCore/Discovery/` and `TetherCore/FTP/` in the iOS
//! package; ports, packet formats, timeouts and replies match the Swift code.
//!
//! Everything here is async on tokio. Discovery sources publish their full
//! current list through a `tokio::sync::watch` channel (the Swift
//! `AsyncStream` that replays the latest value), and [`CameraDiscoverer`]
//! merges them into one deduplicated list.

pub mod discovery;
pub mod ftp;
pub mod net;

pub use discovery::{
    BonjourDiscoverer, CameraDiscoverer, CameraDiscovering, DiscoveredCamera, DiscoveryError,
    DiscoveryMethod, DiscoveryState, FujiDiscoverer, HttpCameraProbe, HttpProbing, ProbeError,
    ReqwestProber, RicohProbe, SsdpDiscoverer,
};
pub use ftp::{
    FtpClient, FtpClientError, FtpConnection, FtpDestination, FtpReply, FtpSecurity, FtpServer,
    FtpServerConfig, FtpServerError, FtpServerEvent, FtpUploading, ReceivedFile,
};

/// PTP/IP's standard TCP port (`PTPIPPacket.standardPort` in Swift). The
/// canonical definition lives in `tether-ptp`'s PTP/IP module; it is repeated
/// here so discovery does not depend on the PTP engine.
pub const PTPIP_STANDARD_PORT: u16 = 15740;

/// Locks a std mutex, recovering the data if a panicking thread poisoned it.
pub(crate) fn lock<T>(m: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}
