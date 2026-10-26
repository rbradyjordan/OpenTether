//! tether-ptp: the PTP engine and its transports, ported from the iOS
//! `TetherCore` package (`PTP/`, `PTPIP/`, `USB/`, `Device/`).
//!
//! - [`ptp`]: wire coding, codes, datasets, [`PtpTransport`] and [`PtpEngine`].
//! - [`ptpip`]: PTP/IP over tokio TCP ([`PtpIpTransport`]).
//! - [`usb`]: the USB container format and, on macOS, the ImageCaptureCore
//!   browser and transport (`UsbCameraBrowser`, `ImageCaptureCoreTransport`).
//! - [`device`]: abstract properties, the [`VendorHandler`] trait, the
//!   generic handler and the registry.
//! - [`vendors`]: the brand handlers (Canon, Nikon, Sony, Fujifilm, Olympus,
//!   Panasonic, Leica over PTP; Ricoh GR, GoPro, OSC over HTTP) and
//!   [`vendors::install_built_ins`].
//! - [`testing`]: a scripted fake transport for tests.

pub mod device;
pub mod ptp;
pub mod ptpip;
pub mod testing;
pub mod usb;
pub mod vendors;

pub use device::{
    camera_identity, detect_vendor, CameraEvent, FocusResult, GenericPtpHandler, NewObject,
    PropertyDescriptor, TetherProperty, VendorHandler, VendorRegistry,
};
pub use ptp::{
    PtpDeviceInfo, PtpEngine, PtpError, PtpEvent, PtpRequest, PtpResponse, PtpResult, PtpTransport,
};
pub use ptpip::{PtpIpConfig, PtpIpTransport};
pub use vendors::{install_built_ins, HttpCameraHandler};
