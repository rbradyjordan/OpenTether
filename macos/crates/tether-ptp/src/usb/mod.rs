//! USB: the portable PTP-over-USB container format, and (macOS only) the
//! ImageCaptureCore browser and transport.

pub mod container;
#[cfg(target_os = "macos")]
pub mod icc;

pub use container::{
    usb_id_hex, ContainerType, Grant, PtpUsbContainer, UsbAuthorizationState, UsbCameraCandidate,
};
#[cfg(target_os = "macos")]
pub use icc::{
    decode_event, decode_response, describe_open_error, DisconnectHandler, IccCamera,
    ImageCaptureCoreTransport, UsbBrowserEvent, UsbCameraBrowser,
};
