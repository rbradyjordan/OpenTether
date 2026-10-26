//! Device layer: abstract properties, the `VendorHandler` trait, the generic
//! PTP handler, the handler registry and identity helpers.

pub mod property;
pub mod support;
pub mod vendor_handler;

pub use property::{format, PropertyChoice, PropertyDescriptor, PropertyForm, TetherProperty};
pub use support::{vendor_props, ObjectHandleDiffer};
pub use vendor_handler::{
    handler_downcast, handler_is, CameraEvent, FocusResult, GenericPtpHandler, HandlerFactory,
    NewObject, PropertyFormatter, VendorHandler, VendorRegistry,
};

use tether_types::{CameraCapabilities, CameraIdentity, CameraVendor, TransportKind};

use crate::ptp::PtpDeviceInfo;

/// Brand from DeviceInfo strings and the vendor extension ID, never from a
/// model allowlist.
pub fn detect_vendor(info: &PtpDeviceInfo) -> CameraVendor {
    CameraVendor::detect(
        &info.manufacturer,
        &info.model,
        &info.vendor_extension_desc,
        info.vendor_extension_id,
    )
}

/// The app-facing identity of a connected PTP camera. The id is
/// `<vendor>-<serial>` when the body reports a serial, else `fallback_id`.
pub fn camera_identity(
    info: &PtpDeviceInfo,
    transport: TransportKind,
    capabilities: CameraCapabilities,
    fallback_id: &str,
) -> CameraIdentity {
    let vendor = detect_vendor(info);
    CameraIdentity {
        id: CameraIdentity::stable_id(vendor, &info.serial_number, fallback_id),
        vendor,
        manufacturer: info.manufacturer.clone(),
        model: info.model.clone(),
        serial_number: info.serial_number.clone(),
        firmware: info.device_version.clone(),
        transport,
        capabilities,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_from_device_info() {
        let info = PtpDeviceInfo {
            manufacturer: "Canon Inc.".into(),
            model: "Canon EOS R5".into(),
            device_version: "1.8.0".into(),
            serial_number: "0123".into(),
            ..Default::default()
        };
        let id = camera_identity(
            &info,
            TransportKind::Usb,
            CameraCapabilities::LIVE_VIEW,
            "usb-x",
        );
        assert_eq!(id.id, "canon-0123");
        assert_eq!(id.vendor, CameraVendor::Canon);
        assert_eq!(id.firmware, "1.8.0");
        let anon = PtpDeviceInfo::default();
        assert_eq!(
            camera_identity(
                &anon,
                TransportKind::PtpIp,
                CameraCapabilities::empty(),
                "ptpip-1"
            )
            .id,
            "ptpip-1"
        );
    }
}
