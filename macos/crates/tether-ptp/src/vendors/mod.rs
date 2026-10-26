//! The brand handlers, ported from `TetherCore/Vendors/`.
//!
//! PTP brands (Canon, Nikon, Sony, Fujifilm, Olympus, Panasonic, Leica) are
//! [`VendorHandler`]s over a [`crate::PtpEngine`] and are picked by
//! [`VendorRegistry::make_handler`] once [`install_built_ins`] has run.
//! HTTP brands (Ricoh GR, GoPro, Open Spherical Camera) are not PTP devices:
//! they implement [`HttpCameraHandler`] and are constructed directly
//! (`RicohHandler::new`, `GoProHandler::new`, `OscHandler::new`), like Swift.
//!
//! The shared helpers Swift kept in `VendorSupport.swift`
//! (`ObjectHandleDiffer`, `VendorProps`, `supportsOp`, `getRawPropValue`)
//! live in [`crate::device::support`], [`crate::ptp::PtpDeviceInfo`] and
//! [`crate::ptp::PtpEngine`].

pub mod canon;
pub mod fujifilm;
pub mod http_cameras;
pub mod leica;
pub mod nikon;
pub mod olympus;
pub mod panasonic;
pub mod ricoh;
pub mod sony;

use std::sync::{Arc, Once};
use std::time::Duration;

use chrono::Utc;
use tether_types::{CameraVendor, LiveViewFrame};

use crate::device::{TetherProperty, VendorHandler, VendorRegistry};
use crate::ptp::{OperationCode, PtpEngine, PtpError, PtpRequest, PtpResponse, PtpResult};

pub use canon::CanonHandler;
pub use fujifilm::FujifilmHandler;
pub use http_cameras::{GoProHandler, HttpCameraHandler, HttpFileCamera, OscHandler};
pub use leica::LeicaHandler;
pub use nikon::NikonHandler;
pub use olympus::OlympusHandler;
pub use panasonic::PanasonicHandler;
pub use ricoh::{
    HttpRequest, ReqwestRicohHttp, RicohHandler, RicohHttp, RicohStreamHandle, RicohWebSocket,
};
pub use sony::SonyHandler;

/// The vendors `install_built_ins` registers.
pub const BUILT_IN_VENDORS: [CameraVendor; 7] = [
    CameraVendor::Canon,
    CameraVendor::Nikon,
    CameraVendor::Sony,
    CameraVendor::Fujifilm,
    CameraVendor::Olympus,
    CameraVendor::Panasonic,
    CameraVendor::Leica,
];

/// Registers every PTP vendor handler this crate ships with the global
/// [`VendorRegistry`]. Safe to call more than once. Ricoh is not registered
/// here: it is reached over HTTP, not PTP, and is constructed directly
/// ([`RicohHandler`]), as are GoPro and OSC cameras.
pub fn install_built_ins() {
    static INSTALLED: Once = Once::new();
    INSTALLED.call_once(|| {
        VendorRegistry::register(
            CameraVendor::Canon,
            Arc::new(|e, i| Arc::new(CanonHandler::new(e, i)) as Arc<dyn VendorHandler>),
        );
        VendorRegistry::register(
            CameraVendor::Nikon,
            Arc::new(|e, i| Arc::new(NikonHandler::new(e, i)) as Arc<dyn VendorHandler>),
        );
        VendorRegistry::register(
            CameraVendor::Sony,
            Arc::new(|e, i| Arc::new(SonyHandler::new(e, i)) as Arc<dyn VendorHandler>),
        );
        VendorRegistry::register(
            CameraVendor::Fujifilm,
            Arc::new(|e, i| Arc::new(FujifilmHandler::new(e, i)) as Arc<dyn VendorHandler>),
        );
        VendorRegistry::register(
            CameraVendor::Olympus,
            Arc::new(|e, i| Arc::new(OlympusHandler::new(e, i)) as Arc<dyn VendorHandler>),
        );
        VendorRegistry::register(
            CameraVendor::Panasonic,
            Arc::new(|e, i| Arc::new(PanasonicHandler::new(e, i)) as Arc<dyn VendorHandler>),
        );
        VendorRegistry::register(
            CameraVendor::Leica,
            Arc::new(|e, i| Arc::new(LeicaHandler::new(e, i)) as Arc<dyn VendorHandler>),
        );
    });
}

// MARK: Shared helpers (crate-private)

/// A live-view frame stamped now (size unknown until decoded).
pub(crate) fn live_frame(jpeg: Vec<u8>, sequence: u64) -> LiveViewFrame {
    LiveViewFrame {
        jpeg,
        sequence,
        timestamp: Utc::now(),
        width: None,
        height: None,
    }
}

/// Swift's `engine.run(op, params, expectsLargeData:, timeout:)`.
pub(crate) async fn run(
    engine: &PtpEngine,
    op: OperationCode,
    params: &[u32],
    timeout_secs: Option<f64>,
    large: bool,
) -> PtpResult<PtpResponse> {
    let mut req = PtpRequest::new(op, params).expecting_large_data(large);
    if let Some(t) = timeout_secs {
        req = req.with_timeout(Duration::from_secs_f64(t));
    }
    engine.run_request(req).await
}

/// Swift's `engine.run(op, params, dataOut:)`.
pub(crate) async fn run_out(
    engine: &PtpEngine,
    op: OperationCode,
    params: &[u32],
    data: Vec<u8>,
) -> PtpResult<PtpResponse> {
    engine
        .run_request(PtpRequest::new(op, params).with_data_out(data))
        .await
}

/// Swift's `_ = try? await engine.execute(PTPRequest(op, parameters:, timeout:))`.
pub(crate) async fn fire(engine: &PtpEngine, op: OperationCode, params: &[u32], timeout_secs: f64) {
    let req = PtpRequest::new(op, params).with_timeout(Duration::from_secs_f64(timeout_secs));
    let _ = engine.execute(req).await;
}

pub(crate) fn cannot_set(p: TetherProperty) -> PtpError {
    PtpError::Unsupported(format!(
        "{} cannot be set on this camera.",
        p.display_name()
    ))
}

pub(crate) fn needs_numeric(p: TetherProperty) -> PtpError {
    PtpError::Unsupported(format!("{} needs a numeric value.", p.display_name()))
}

pub(crate) fn no_live_view() -> PtpError {
    PtpError::Unsupported("Live view is not available on this camera.".into())
}

/// `%.0f` / `%.1f` f-number display, as the Swift tables do.
pub(crate) fn f_number(f: f64) -> String {
    if f == f.round() {
        format!("ƒ/{f:.0}")
    } else {
        format!("ƒ/{f:.1}")
    }
}
