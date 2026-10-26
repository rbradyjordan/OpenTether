//! Canon EOS: PC remote mode, polled GetEvent stream, EOS property codes,
//! two-stage shutter, SDRAM transfer, EVF live view and touch AF.
//! Ported from `CanonHandler.swift`.
//!
//! Every Canon EOS constant lives in [`op`], [`prop`], [`event`] and the
//! value tables below so a wrong one is fixed in one place. Names follow
//! libgphoto2 `ptp.h` (`PTP_OC_CANON_EOS_*`, `PTP_DPC_CANON_EOS_*`,
//! `PTP_EC_CANON_EOS_*`). Values marked VERIFY have not been checked against
//! a body from this code base.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tether_types::{
    jpeg_payload, CameraCapabilities, CameraVendor, CaptureDestination, LiveViewFrame,
    LiveViewQuality,
};

use super::{cannot_set, fire, live_frame, needs_numeric, no_live_view, run, run_out};
use crate::device::property::format;
use crate::device::{
    CameraEvent, FocusResult, GenericPtpHandler, NewObject, PropertyChoice, PropertyDescriptor,
    PropertyForm, TetherProperty, VendorHandler,
};
use crate::ptp::transport::lock;
use crate::ptp::{
    ByteBuffer, EventCode, ObjectFormat, OperationCode, ProgressFn, PtpDeviceInfo, PtpEngine,
    PtpError, PtpEvent, PtpObjectInfo, PtpRequest, PtpResult, PtpValue, ResponseCode,
};

/// Canon EOS operation codes.
pub mod op {
    use crate::ptp::OperationCode as O;
    pub const GET_STORAGE_IDS: O = O(0x9101);
    pub const GET_STORAGE_INFO: O = O(0x9102);
    pub const GET_OBJECT_INFO: O = O(0x9103);
    pub const GET_OBJECT: O = O(0x9104);
    pub const DELETE_OBJECT: O = O(0x9105);
    pub const FORMAT_STORE: O = O(0x9106);
    pub const GET_PARTIAL_OBJECT_EX: O = O(0x9107);
    pub const SET_OBJECT_ATTRIBUTES: O = O(0x9108);
    pub const GET_OBJECT_TIME: O = O(0x9109);
    pub const SET_OBJECT_TIME: O = O(0x910A);
    pub const REMOTE_RELEASE: O = O(0x910F);
    pub const SET_DEVICE_PROP_VALUE_EX: O = O(0x9110);
    pub const GET_REMOTE_MODE: O = O(0x9113);
    pub const SET_REMOTE_MODE: O = O(0x9114);
    pub const SET_EVENT_MODE: O = O(0x9115);
    pub const GET_EVENT: O = O(0x9116);
    pub const TRANSFER_COMPLETE: O = O(0x9117);
    pub const CANCEL_TRANSFER: O = O(0x9118);
    pub const RESET_TRANSFER: O = O(0x9119);
    pub const PC_HDD_CAPACITY: O = O(0x911A);
    pub const SET_UI_LOCK: O = O(0x911B);
    pub const RESET_UI_LOCK: O = O(0x911C);
    pub const KEEP_DEVICE_ON: O = O(0x911D);
    pub const REQUEST_DEVICE_PROP_VALUE: O = O(0x9127);
    pub const REMOTE_RELEASE_ON: O = O(0x9128);
    pub const REMOTE_RELEASE_OFF: O = O(0x9129);
    pub const GET_VIEW_FINDER_DATA: O = O(0x9153);
    pub const DO_AF: O = O(0x9154);
    /// 3 args: type, x, y (libgphoto2 ptp.h); x/y in the AF coordinate
    /// space FocusInfoEx reports.
    pub const TOUCH_AF_POSITION: O = O(0x915B);
    pub const DRIVE_LENS: O = O(0x9155);
    pub const AF_CANCEL: O = O(0x9160);
    /// Turns on OLCInfoChanged events (libgphoto2 sends mask 0x1FFF when preparing to capture).
    pub const SET_REQUEST_OLC_INFO_GROUP: O = O(0x913D);
    /// VERIFY: libgphoto2 PTP_OC_CANON_EOS_GetPartialObjectEx64.
    pub const GET_PARTIAL_OBJECT_EX64: O = O(0x9187);
}

/// Canon EOS property codes (32-bit on the wire) and their special values.
pub mod prop {
    pub const APERTURE: u32 = 0xD101;
    pub const SHUTTER_SPEED: u32 = 0xD102;
    pub const ISO: u32 = 0xD103;
    pub const EXP_COMPENSATION: u32 = 0xD104;
    pub const AUTO_EXPOSURE_MODE: u32 = 0xD105;
    pub const DRIVE_MODE: u32 = 0xD106;
    pub const METERING_MODE: u32 = 0xD107;
    pub const FOCUS_MODE: u32 = 0xD108;
    /// Layout version of OLCInfoChanged records (libgphoto2 PTP_DPC_CANON_EOS_OLCInfoVersion).
    pub const OLC_INFO_VERSION: u32 = 0xD199;
    pub const WHITE_BALANCE: u32 = 0xD109;
    pub const COLOR_TEMPERATURE: u32 = 0xD10A;
    pub const PICTURE_STYLE: u32 = 0xD110;
    pub const BATTERY_POWER: u32 = 0xD111;
    pub const BATTERY_SELECT: u32 = 0xD112;
    pub const AVAILABLE_SHOTS: u32 = 0xD11B;
    pub const CAPTURE_DESTINATION: u32 = 0xD11C;
    /// VERIFY: libgphoto2 PTP_DPC_CANON_EOS_LensName.
    pub const LENS_NAME: u32 = 0xD1C0;
    pub const EVF_OUTPUT_DEVICE: u32 = 0xD1B0;
    /// FocusInfoEx: AF points plus the AF coordinate space (width, height).
    pub const FOCUS_INFO_EX: u32 = 0xD1D3;
    pub const EVF_MODE: u32 = 0xD1B3;
    pub const EVF_WHITE_BALANCE: u32 = 0xD1B4;
    pub const EVF_ZOOM: u32 = 0xD1BC;

    /// CaptureDestination values. VERIFY: libgphoto2 "capturetarget" uses
    /// 1 = memory card, 4 = internal RAM; 6 (card + RAM) is the EDSDK
    /// "both" value as observed in sniffs, not from libgphoto2.
    pub const DESTINATION_CARD: u32 = 1;
    pub const DESTINATION_HOST: u32 = 4;
    pub const DESTINATION_BOTH: u32 = 6;

    pub const EVF_OUTPUT_PC: u32 = 2;
    pub const EVF_OUTPUT_OFF: u32 = 0;
}

/// Canon EOS event record types (GetEvent dump) / pushed event codes.
pub mod event {
    pub const REQUEST_GET_EVENT: u32 = 0xC101;
    pub const OBJECT_ADDED_EX: u32 = 0xC181;
    pub const OBJECT_REMOVED: u32 = 0xC182;
    pub const REQUEST_GET_OBJECT_INFO_EX: u32 = 0xC183;
    pub const STORAGE_STATUS_CHANGED: u32 = 0xC184;
    pub const STORAGE_INFO_CHANGED: u32 = 0xC185;
    pub const REQUEST_OBJECT_TRANSFER: u32 = 0xC186;
    pub const OBJECT_INFO_CHANGED_EX: u32 = 0xC187;
    pub const OBJECT_CONTENT_CHANGED: u32 = 0xC188;
    /// VERIFY: libgphoto2 PTP_EC_CANON_EOS_PropValueChanged; some notes list 0xC186.
    pub const PROP_VALUE_CHANGED: u32 = 0xC189;
    /// VERIFY: libgphoto2 PTP_EC_CANON_EOS_AvailListChanged; some notes list 0xC189.
    pub const AVAIL_LIST_CHANGED: u32 = 0xC18A;
    /// VERIFY: libgphoto2 PTP_EC_CANON_EOS_CameraStatusChanged; some notes list 0xC18A.
    pub const CAMERA_STATUS_CHANGED: u32 = 0xC18B;
    /// VERIFY: libgphoto2 PTP_EC_CANON_EOS_WillSoonShutdown; some notes list 0xC18B.
    pub const WILL_SOON_SHUTDOWN: u32 = 0xC18D;
    pub const SHUTDOWN_TIMER_UPDATED: u32 = 0xC18E;
    pub const REQUEST_CANCEL_TRANSFER: u32 = 0xC18F;
    pub const REQUEST_OBJECT_TRANSFER_DT: u32 = 0xC190;
    pub const STORE_ADDED: u32 = 0xC192;
    pub const STORE_REMOVED: u32 = 0xC193;
    pub const BULB_EXPOSURE_TIME: u32 = 0xC194;
    pub const RECORDING_TIME: u32 = 0xC195;
    pub const AF_RESULT: u32 = 0xC1A3;
    /// On-screen info changes, incl. the live AF state (libgphoto2 PTP_EC_CANON_EOS_OLCInfoChanged).
    pub const OLC_INFO_CHANGED: u32 = 0xC1A5;
    /// VERIFY: libgphoto2 PTP_EC_CANON_EOS_ObjectAddedEx64.
    pub const OBJECT_ADDED_EX64: u32 = 0xC1A7;
    /// VERIFY: libgphoto2 PTP_EC_CANON_EOS_ObjectAddedUnknown64.
    pub const OBJECT_ADDED_UNKNOWN64: u32 = 0xC1A8;
    pub const REQUEST_OBJECT_TRANSFER64: u32 = 0xC1A9;
    /// Newer bodies (R-series): same as above with no filename.
    /// libgphoto2 PTP_EC_CANON_EOS_RequestObjectTransfer64LFN.
    pub const REQUEST_OBJECT_TRANSFER64_LFN: u32 = 0xC1B8;
}

/// Offsets inside a RequestObjectTransfer record (libgphoto2 `PTP_cee_OI_*`);
/// the 64-bit variant uses the same ones, the LFN variant has no name.
pub mod transfer_request_layout {
    pub const HANDLE: usize = 8;
    pub const FORMAT: usize = 0x0C;
    pub const SIZE: usize = 0x14;
    pub const NAME: usize = 0x1C;
}

/// Offsets inside an ObjectAddedEx record (from the record start).
/// VERIFY: libgphoto2 `PTP_ece_OA_*`.
pub mod object_added_layout {
    pub const HANDLE: usize = 8;
    pub const STORAGE_ID: usize = 0x0C;
    pub const FORMAT: usize = 0x10;
    pub const SIZE: usize = 0x1C;
    pub const PARENT: usize = 0x20;
    pub const NAME: usize = 0x28;
    /// ObjectAddedEx64: 64-bit size, everything after shifts by 4.
    /// VERIFY: libgphoto2 `PTP_ece2_OA_*`.
    pub const SIZE64: usize = 0x1C;
    pub const PARENT64: usize = 0x24;
    pub const NAME64: usize = 0x2C;
}

/// FocusMode (0xD108) values (libgphoto2 eos_focusmodes): 0 One Shot,
/// 1 AI Servo, 2 AI Focus, 3 Manual.
pub const FOCUS_MODE_ONE_SHOT: u32 = 0;
pub const FOCUS_MODE_SERVO: u32 = 1;
pub const FOCUS_MODE_AI_FOCUS: u32 = 2;

/// OLCInfoChanged field sizes per layout version, for mask bits 0x1…0x1000
/// (libgphoto2 ptp-pack.c `olcsizes`; 0x14 confirmed there on R8, R10, R5 Mark II).
pub const OLC_SIZES: [&[usize]; 21] = [
    &[],
    &[],
    &[],
    &[],
    &[],
    &[],
    &[],
    &[2, 6, 5, 4, 4, 6, 7, 4, 6, 5, 5, 8, 1], // 0x07
    &[2, 6, 5, 4, 4, 6, 7, 4, 6, 7, 7, 8, 1], // 0x08
    &[2, 6, 5, 4, 4, 6, 7, 4, 6, 7, 7, 8, 1], // 0x09
    &[2, 6, 5, 4, 4, 6, 7, 4, 6, 7, 7, 8, 1], // 0x0A
    &[2, 6, 5, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1], // 0x0B
    &[2, 6, 5, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1], // 0x0C
    &[2, 6, 5, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1], // 0x0D
    &[2, 6, 5, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1], // 0x0E
    &[2, 7, 6, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1], // 0x0F
    &[2, 7, 6, 4, 4, 6, 8, 4, 6, 5, 5, 9, 1], // 0x10
    &[2, 7, 6, 6, 4, 6, 8, 4, 6, 5, 5, 9, 8], // 0x11 EOS R
    &[2, 7, 9, 6, 4, 6, 8, 5, 7, 5, 5, 9, 8], // 0x12
    &[2, 7, 9, 7, 4, 6, 8, 5, 7, 5, 5, 9, 8], // 0x13 R5, R5 C
    &[2, 9, 9, 7, 4, 6, 8, 5, 7, 5, 5, 9, 8], // 0x14 R8, R10, R5 Mark II
];
/// OLC field carrying the AF state.
pub const OLC_FOCUS_INFO_MASK: u16 = 0x0100;

/// GetViewFinderData record types.
pub const VIEW_FINDER_JPEG_RECORD: u32 = 1;
/// TouchAfPosition `type` argument. VERIFY on hardware: libgphoto2
/// leaves it to the caller; 0 is assumed to mean "move the AF frame".
pub const TOUCH_AF_TYPE: u32 = 0;

/// Canon "not ready" (live view still starting).
pub const NOT_READY: ResponseCode = ResponseCode(0xA102);
/// VERIFY: libgphoto2 uses 0x00100000; newer bodies accept 0x00200000.
pub const VIEW_FINDER_PARAM: u32 = 0x0010_0000;

// MARK: Value tables (libgphoto2 camlibs/ptp2/config.c). All VERIFY.

/// EOS aperture code → f-number. VERIFY: libgphoto2 `canon_aperture`.
pub const APERTURES: &[(u32, f64)] = &[
    (0x08, 1.0),
    (0x0B, 1.1),
    (0x0C, 1.2),
    (0x0D, 1.2),
    (0x10, 1.4),
    (0x13, 1.6),
    (0x14, 1.8),
    (0x15, 1.8),
    (0x18, 2.0),
    (0x1B, 2.2),
    (0x1C, 2.5),
    (0x1D, 2.5),
    (0x20, 2.8),
    (0x23, 3.2),
    (0x24, 3.5),
    (0x25, 3.5),
    (0x28, 4.0),
    (0x2B, 4.5),
    (0x2C, 4.5),
    (0x2D, 5.0),
    (0x30, 5.6),
    (0x33, 6.3),
    (0x34, 6.7),
    (0x35, 7.1),
    (0x38, 8.0),
    (0x3B, 9.0),
    (0x3C, 9.5),
    (0x3D, 10.0),
    (0x40, 11.0),
    (0x43, 13.0),
    (0x44, 13.0),
    (0x45, 14.0),
    (0x48, 16.0),
    (0x4B, 18.0),
    (0x4C, 19.0),
    (0x4D, 20.0),
    (0x50, 22.0),
    (0x53, 25.0),
    (0x54, 27.0),
    (0x55, 29.0),
    (0x58, 32.0),
    (0x5B, 36.0),
    (0x5C, 38.0),
    (0x5D, 40.0),
    (0x60, 45.0),
    (0x63, 51.0),
    (0x64, 54.0),
    (0x65, 57.0),
    (0x68, 64.0),
    (0x6B, 72.0),
    (0x6C, 76.0),
    (0x6D, 80.0),
    (0x70, 91.0),
];

/// EOS shutter code → seconds (0 = bulb). VERIFY: libgphoto2 `canon_shutterspeed`.
pub const SHUTTERS: &[(u32, f64)] = &[
    (0x0C, 0.0),
    (0x10, 30.0),
    (0x13, 25.0),
    (0x14, 20.0),
    (0x15, 20.0),
    (0x18, 15.0),
    (0x1B, 13.0),
    (0x1C, 10.0),
    (0x1D, 10.0),
    (0x20, 8.0),
    (0x23, 6.0),
    (0x24, 6.0),
    (0x25, 5.0),
    (0x28, 4.0),
    (0x2B, 3.2),
    (0x2C, 3.0),
    (0x2D, 2.5),
    (0x30, 2.0),
    (0x33, 1.6),
    (0x34, 1.5),
    (0x35, 1.3),
    (0x38, 1.0),
    (0x3B, 0.8),
    (0x3C, 0.7),
    (0x3D, 0.6),
    (0x40, 0.5),
    (0x43, 0.4),
    (0x44, 0.3),
    (0x45, 0.3),
    (0x48, 1.0 / 4.0),
    (0x4B, 1.0 / 5.0),
    (0x4C, 1.0 / 6.0),
    (0x4D, 1.0 / 6.0),
    (0x50, 1.0 / 8.0),
    (0x53, 1.0 / 10.0),
    (0x54, 1.0 / 10.0),
    (0x55, 1.0 / 13.0),
    (0x58, 1.0 / 15.0),
    (0x5B, 1.0 / 20.0),
    (0x5C, 1.0 / 20.0),
    (0x5D, 1.0 / 25.0),
    (0x60, 1.0 / 30.0),
    (0x63, 1.0 / 40.0),
    (0x64, 1.0 / 45.0),
    (0x65, 1.0 / 50.0),
    (0x68, 1.0 / 60.0),
    (0x6B, 1.0 / 80.0),
    (0x6C, 1.0 / 90.0),
    (0x6D, 1.0 / 100.0),
    (0x70, 1.0 / 125.0),
    (0x73, 1.0 / 160.0),
    (0x74, 1.0 / 180.0),
    (0x75, 1.0 / 200.0),
    (0x78, 1.0 / 250.0),
    (0x7B, 1.0 / 320.0),
    (0x7C, 1.0 / 350.0),
    (0x7D, 1.0 / 400.0),
    (0x80, 1.0 / 500.0),
    (0x83, 1.0 / 640.0),
    (0x84, 1.0 / 750.0),
    (0x85, 1.0 / 800.0),
    (0x88, 1.0 / 1000.0),
    (0x8B, 1.0 / 1250.0),
    (0x8C, 1.0 / 1500.0),
    (0x8D, 1.0 / 1600.0),
    (0x90, 1.0 / 2000.0),
    (0x93, 1.0 / 2500.0),
    (0x94, 1.0 / 3000.0),
    (0x95, 1.0 / 3200.0),
    (0x98, 1.0 / 4000.0),
    (0x9B, 1.0 / 5000.0),
    (0x9C, 1.0 / 6000.0),
    (0x9D, 1.0 / 6400.0),
    (0xA0, 1.0 / 8000.0),
    (0xA3, 1.0 / 10000.0),
    (0xA5, 1.0 / 12800.0),
    (0xA8, 1.0 / 16000.0),
];

/// EOS ISO code → ISO (0 = Auto). VERIFY: libgphoto2 `canon_isospeed`.
pub const ISOS: &[(u32, u32)] = &[
    (0x00, 0),
    (0x28, 6),
    (0x30, 12),
    (0x38, 25),
    (0x40, 50),
    (0x43, 64),
    (0x45, 80),
    (0x48, 100),
    (0x4B, 125),
    (0x4D, 160),
    (0x50, 200),
    (0x53, 250),
    (0x55, 320),
    (0x58, 400),
    (0x5B, 500),
    (0x5D, 640),
    (0x60, 800),
    (0x63, 1000),
    (0x65, 1250),
    (0x68, 1600),
    (0x6B, 2000),
    (0x6D, 2500),
    (0x70, 3200),
    (0x73, 4000),
    (0x75, 5000),
    (0x78, 6400),
    (0x7B, 8000),
    (0x7D, 10000),
    (0x80, 12800),
    (0x83, 16000),
    (0x85, 20000),
    (0x88, 25600),
    (0x8B, 32000),
    (0x8D, 40000),
    (0x90, 51200),
    (0x93, 64000),
    (0x95, 80000),
    (0x98, 102400),
    (0xA0, 204800),
    (0xA8, 409600),
];

/// EOS white balance. VERIFY: libgphoto2 `canon_whitebalance` (EOS column).
pub const WHITE_BALANCES: &[(u32, &str)] = &[
    (0, "Auto"),
    (1, "Daylight"),
    (2, "Cloudy"),
    (3, "Tungsten"),
    (4, "Fluorescent"),
    (5, "Flash"),
    (6, "Manual"),
    (8, "Shade"),
    (9, "Color temperature"),
    (10, "Custom 1"),
    (11, "Custom 2"),
    (12, "Custom 3"),
    (15, "Manual 2"),
    (16, "Manual 3"),
    (18, "Manual 4"),
    (19, "Manual 5"),
    (20, "Custom 4"),
    (21, "Custom 5"),
    (23, "Auto (white priority)"),
];

/// EOS BatteryPower levels. VERIFY: libgphoto2 `_get_Canon_EOS_BatteryLevel`.
pub const BATTERY_LEVELS: &[(u32, &str)] =
    &[(0, "Low"), (1, "50%"), (2, "100%"), (4, "75%"), (5, "25%")];

/// Properties the camera never lets us write.
pub const READ_ONLY: [u32; 3] = [prop::BATTERY_POWER, prop::AVAILABLE_SHOTS, prop::LENS_NAME];

fn lookup<V: Copy>(table: &[(u32, V)], key: u32) -> Option<V> {
    table.iter().find(|(k, _)| *k == key).map(|(_, v)| *v)
}

/// Exposure compensation: signed 8-bit in 1/8 EV with 1/3-stop rounding
/// (0x03 = +1/3, 0x04 = +1/2, 0x05 = +2/3, 0x08 = +1, 0xF8 = -1).
/// VERIFY: libgphoto2 `canon_expcompensation`.
pub fn exposure_compensation(code: u32) -> String {
    let v = code as u8 as i8;
    if v == 0 {
        return "0".into();
    }
    let sign = if v < 0 { "-" } else { "+" };
    let eighths = i32::from(v).abs();
    let whole = eighths / 8;
    let frac = match eighths % 8 {
        0 => String::new(),
        3 => "1/3".into(),
        4 => "1/2".into(),
        5 => "2/3".into(),
        n => format!("{n}/8"),
    };
    if whole == 0 {
        return format!("{sign}{frac}");
    }
    if frac.is_empty() {
        format!("{sign}{whole}")
    } else {
        format!("{sign}{whole} {frac}")
    }
}

/// Display string for an EOS property value.
pub fn display(prop_code: u32, value: u32) -> String {
    match prop_code {
        prop::APERTURE => {
            // 0 = the lens reports no aperture (no lens, manual or adapted lens).
            if value == 0 {
                return "—".into();
            }
            match lookup(APERTURES, value) {
                Some(f) => super::f_number(f),
                None => format!("ƒ/?(0x{value:02X})"),
            }
        }
        prop::SHUTTER_SPEED => match lookup(SHUTTERS, value) {
            Some(s) => format::shutter_seconds(s),
            None => format!("?(0x{value:02X})"),
        },
        prop::ISO => match lookup(ISOS, value) {
            Some(0) => "Auto".into(),
            Some(i) => i.to_string(),
            None => format!("ISO ?(0x{value:02X})"),
        },
        prop::EXP_COMPENSATION => exposure_compensation(value),
        prop::WHITE_BALANCE => {
            lookup(WHITE_BALANCES, value).map_or_else(|| format!("WB {value}"), str::to_string)
        }
        prop::BATTERY_POWER => {
            lookup(BATTERY_LEVELS, value).map_or_else(|| format!("{value}%"), str::to_string)
        }
        prop::CAPTURE_DESTINATION => match value {
            prop::DESTINATION_CARD => CaptureDestination::Card.display_name().into(),
            prop::DESTINATION_HOST => CaptureDestination::Host.display_name().into(),
            prop::DESTINATION_BOTH => CaptureDestination::Both.display_name().into(),
            _ => format!("Destination {value}"),
        },
        prop::COLOR_TEMPERATURE => format!("{value} K"),
        _ => value.to_string(),
    }
}

/// The abstract property for an EOS property code.
pub fn property_for(prop_code: u32) -> Option<TetherProperty> {
    use TetherProperty as P;
    Some(match prop_code {
        prop::APERTURE => P::Aperture,
        prop::SHUTTER_SPEED => P::ShutterSpeed,
        prop::ISO => P::Iso,
        prop::EXP_COMPENSATION => P::ExposureCompensation,
        prop::WHITE_BALANCE => P::WhiteBalance,
        prop::COLOR_TEMPERATURE => P::ColorTemperature,
        prop::AUTO_EXPOSURE_MODE => P::ExposureProgram,
        prop::DRIVE_MODE => P::DriveMode,
        prop::METERING_MODE => P::MeteringMode,
        prop::FOCUS_MODE => P::FocusMode,
        prop::PICTURE_STYLE => P::PictureStyle,
        prop::BATTERY_POWER => P::BatteryLevel,
        prop::AVAILABLE_SHOTS => P::StorageFreeImages,
        prop::CAPTURE_DESTINATION => P::CaptureDestination,
        prop::EVF_MODE => P::LiveViewEnabled,
        prop::LENS_NAME => P::LensName,
        _ => return None,
    })
}

/// The EOS property code for an abstract property.
pub fn code_for(p: TetherProperty) -> Option<u32> {
    use TetherProperty as P;
    Some(match p {
        P::Aperture => prop::APERTURE,
        P::ShutterSpeed => prop::SHUTTER_SPEED,
        P::Iso => prop::ISO,
        P::ExposureCompensation => prop::EXP_COMPENSATION,
        P::WhiteBalance => prop::WHITE_BALANCE,
        P::ColorTemperature => prop::COLOR_TEMPERATURE,
        P::ExposureProgram => prop::AUTO_EXPOSURE_MODE,
        P::DriveMode => prop::DRIVE_MODE,
        P::MeteringMode => prop::METERING_MODE,
        P::FocusMode => prop::FOCUS_MODE,
        P::PictureStyle => prop::PICTURE_STYLE,
        P::BatteryLevel => prop::BATTERY_POWER,
        P::StorageFreeImages => prop::AVAILABLE_SHOTS,
        P::CaptureDestination => prop::CAPTURE_DESTINATION,
        P::LiveViewEnabled => prop::EVF_MODE,
        P::LensName => prop::LENS_NAME,
        _ => return None,
    })
}

// MARK: Event records

/// One record of a Canon EOS GetEvent dump.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CanonEventRecord {
    pub record_type: u32,
    /// Raw record bytes including the 8-byte (size, type) header.
    pub bytes: Vec<u8>,
}

impl CanonEventRecord {
    /// Splits a GetEvent payload. Stops at the terminator (size 8, type 0)
    /// or when a size does not fit.
    pub fn parse(data: &[u8]) -> Vec<CanonEventRecord> {
        let mut out = Vec::new();
        let mut pos = 0usize;
        while pos + 8 <= data.len() {
            let size = u32::from_le_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]])
                as usize;
            let record_type =
                u32::from_le_bytes([data[pos + 4], data[pos + 5], data[pos + 6], data[pos + 7]]);
            if size < 8 || pos + size > data.len() {
                break;
            }
            if size == 8 && record_type == 0 {
                break;
            }
            out.push(CanonEventRecord {
                record_type,
                bytes: data[pos..pos + size].to_vec(),
            });
            pos += size;
        }
        out
    }

    pub fn u32_at(&self, offset: usize) -> Option<u32> {
        let b = self.bytes.get(offset..offset.checked_add(4)?)?;
        Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub fn u64_at(&self, offset: usize) -> Option<u64> {
        let b = self.bytes.get(offset..offset.checked_add(8)?)?;
        let mut a = [0u8; 8];
        a.copy_from_slice(b);
        Some(u64::from_le_bytes(a))
    }

    pub fn u16_at(&self, offset: usize) -> Option<u16> {
        let b = self.bytes.get(offset..offset.checked_add(2)?)?;
        Some(u16::from_le_bytes([b[0], b[1]]))
    }

    /// ASCII NUL-terminated string at `offset`.
    pub fn c_string(&self, offset: usize) -> String {
        let Some(slice) = self.bytes.get(offset..) else {
            return String::new();
        };
        let end = slice.iter().position(|&b| b == 0).unwrap_or(slice.len());
        String::from_utf8_lossy(&slice[..end]).into_owned()
    }
}

/// AF state from OLC focus info, latched per touch: libgphoto2 traces
/// show success as 00-01 → 01-01 → 00-00 (R8 skips straight from 01-01
/// to 00-00) and failure as 00-01 → 02-01 → 02-00 → 00-00 (R5 Mark II).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AfState {
    Idle,
    Running,
    Focused,
    Failed,
}

// MARK: Handler

struct CanonState {
    /// Last known value per EOS property (filled from the event stream).
    values: HashMap<u32, u32>,
    /// Allowed values per EOS property (AvailListChanged).
    available: HashMap<u32, Vec<u32>>,
    pending: Vec<CameraEvent>,
    destination: CaptureDestination,
    live_view_on: bool,
    /// AF coordinate space from FocusInfoEx, once the body has sent it.
    af_coordinate_space: Option<(u32, u32)>,
    live_view_started: Instant,
    live_view_has_frame: bool,
    frame_sequence: u64,
    af_outcome: Option<FocusResult>,
    af_saw_running: bool,
    focus_info_reported_focus: bool,
    tracking_focus: bool,
    /// The user's AF mode while a tap has the body in One Shot.
    focus_mode_before_touch: Option<u32>,
}

/// Canon EOS: PC remote mode, polled GetEvent stream, EOS property codes,
/// two-stage shutter, SDRAM transfer and EVF live view.
pub struct CanonHandler {
    pub engine: Arc<PtpEngine>,
    pub info: PtpDeviceInfo,
    capabilities: CameraCapabilities,
    generic: GenericPtpHandler,
    state: Mutex<CanonState>,
}

impl CanonHandler {
    /// Longest wait for the body's AF report (slow lenses in low light take
    /// several seconds; libgphoto2 allows up to 8 s for a half-press).
    pub const TOUCH_AF_REPORT_TIMEOUT: Duration = Duration::from_secs(8);
    /// Bodies with no AF report: how long to show "focusing".
    pub const TOUCH_AF_FALLBACK_TIME: Duration = Duration::from_millis(2500);
    /// Without a first frame by then, the body is not going to send one.
    pub const LIVE_VIEW_START_TIMEOUT: Duration = Duration::from_secs(8);

    pub fn new(engine: Arc<PtpEngine>, info: PtpDeviceInfo) -> Self {
        use CameraCapabilities as C;
        let generic = GenericPtpHandler::new(engine.clone(), info.clone(), None);
        let mut caps = C::empty();
        let two_stage = info.supports_op(op::REMOTE_RELEASE_ON);
        if two_stage || info.supports_op(op::REMOTE_RELEASE) {
            caps |= C::REMOTE_CAPTURE | C::CARD_CAPTURE;
        }
        if info.supports_op(op::GET_PARTIAL_OBJECT_EX) && info.supports_op(op::TRANSFER_COMPLETE) {
            caps |= C::SDRAM_CAPTURE;
        }
        if info.supports_op(op::GET_PARTIAL_OBJECT_EX)
            || info.supports_op(OperationCode::GET_PARTIAL_OBJECT)
        {
            caps |= C::PARTIAL_TRANSFER;
        }
        if info.supports_op(op::GET_VIEW_FINDER_DATA) {
            caps |= C::LIVE_VIEW;
        }
        if info.supports_op(op::SET_DEVICE_PROP_VALUE_EX) {
            caps |= C::PROPERTY_CONTROL;
        }
        if two_stage || info.supports_op(op::DO_AF) {
            caps |= C::AUTOFOCUS;
        }
        if info.supports_op(OperationCode::GET_THUMB) {
            caps |= C::THUMBNAILS;
        }
        if info.supports_op(op::REMOTE_RELEASE_ON) {
            caps |= C::BULB_CAPTURE;
        }
        if info.supports_op(op::TOUCH_AF_POSITION) && info.supports_op(op::GET_VIEW_FINDER_DATA) {
            caps |= C::TOUCH_AUTOFOCUS;
        }
        Self {
            engine,
            info,
            capabilities: caps,
            generic,
            state: Mutex::new(CanonState {
                values: HashMap::new(),
                available: HashMap::new(),
                pending: Vec::new(),
                destination: CaptureDestination::Card,
                live_view_on: false,
                af_coordinate_space: None,
                live_view_started: Instant::now(),
                live_view_has_frame: false,
                frame_sequence: 0,
                af_outcome: None,
                af_saw_running: false,
                focus_info_reported_focus: false,
                tracking_focus: false,
                focus_mode_before_touch: None,
            }),
        }
    }

    // MARK: Cache accessors (Swift exposed these to tests as `values` / `available`)

    /// Last known value of an EOS property.
    pub fn value(&self, prop_code: u32) -> Option<u32> {
        lock(&self.state).values.get(&prop_code).copied()
    }

    /// Allowed values of an EOS property, from AvailListChanged.
    pub fn available(&self, prop_code: u32) -> Option<Vec<u32>> {
        lock(&self.state).available.get(&prop_code).cloned()
    }

    /// AF coordinate space from FocusInfoEx, once the body has sent it.
    pub fn af_coordinate_space(&self) -> Option<(u32, u32)> {
        lock(&self.state).af_coordinate_space
    }

    /// Where captures currently go.
    pub fn destination(&self) -> CaptureDestination {
        lock(&self.state).destination
    }

    fn push_pending(&self, events: Vec<CameraEvent>) {
        lock(&self.state).pending.extend(events);
    }

    // MARK: Capture helpers

    /// With captures going to the host, the body needs to hear how much room
    /// the host has; without it, it assumes none, shows "PC full" and refuses
    /// to fire (DeviceBusy). libgphoto2 sends the same fixed, large figure.
    async fn report_host_capacity(&self) -> PtpResult<()> {
        if self.destination() == CaptureDestination::Card
            || !self.info.supports_op(op::PC_HDD_CAPACITY)
        {
            return Ok(());
        }
        run(
            &self.engine,
            op::PC_HDD_CAPACITY,
            &[0x0FFF_FFFF, 0x0000_1000, 0x0000_0001],
            None,
            false,
        )
        .await
        .map(|_| ())
    }

    /// One shutter stage; a failed press releases what it held.
    async fn press(&self, stage: u32) -> PtpResult<()> {
        if let Err(e) = run(
            &self.engine,
            op::REMOTE_RELEASE_ON,
            &[stage, 0],
            Some(15.0),
            false,
        )
        .await
        {
            self.release(&[stage]).await;
            return Err(e);
        }
        if stage == 3 {
            self.release(&[3]).await;
        }
        Ok(())
    }

    /// Releases never throw: a stuck half-press is worse than a lost error.
    async fn release(&self, stages: &[u32]) {
        for &stage in stages {
            let _ = self
                .engine
                .execute(PtpRequest::new(op::REMOTE_RELEASE_OFF, [stage]))
                .await;
        }
    }

    pub fn is_busy(error: &PtpError) -> bool {
        error.response_code() == Some(ResponseCode::DEVICE_BUSY)
    }

    async fn two_stage_capture(&self, autofocus: bool) -> PtpResult<()> {
        if autofocus {
            match self.press(1).await {
                Ok(()) => {}
                Err(e) if Self::is_busy(&e) => {
                    // AF could not start or lock (manual lens, nothing to
                    // focus on): fire without AF rather than not at all.
                    return self.press(3).await;
                }
                Err(e) => return Err(e),
            }
            if let Err(e) = self.press(2).await {
                self.release(&[1]).await; // don't leave it half-pressed
                return Err(e);
            }
            self.release(&[2, 1]).await;
            Ok(())
        } else {
            self.press(3).await
        }
    }

    // MARK: Events

    async fn fetch_events(&self) -> PtpResult<Vec<CameraEvent>> {
        if !self.info.supports_op(op::GET_EVENT) {
            return Ok(Vec::new());
        }
        let r = run(&self.engine, op::GET_EVENT, &[], None, true).await?;
        Ok(self.ingest(&r.data_in))
    }

    /// Parses a GetEvent dump, updates the property caches and returns the
    /// vendor-neutral events.
    pub fn ingest(&self, dump: &[u8]) -> Vec<CameraEvent> {
        let mut out = Vec::new();
        let mut s = lock(&self.state);
        for rec in CanonEventRecord::parse(dump) {
            match rec.record_type {
                event::OBJECT_ADDED_EX
                | event::OBJECT_ADDED_EX64
                | event::OBJECT_ADDED_UNKNOWN64 => {
                    let is64 = rec.record_type != event::OBJECT_ADDED_EX;
                    if let Some(obj) = Self::object_added(&rec, is64, s.destination) {
                        // Card copies while shooting to the host arrive again as a
                        // transfer request; only one of the two is downloaded.
                        if obj.in_sdram || s.destination == CaptureDestination::Card {
                            out.push(CameraEvent::ObjectAdded(obj));
                        }
                    }
                }
                event::REQUEST_OBJECT_TRANSFER
                | event::REQUEST_OBJECT_TRANSFER64
                | event::REQUEST_OBJECT_TRANSFER64_LFN => {
                    // A capture waiting in the body's memory; it holds the card
                    // and stays busy until we take it.
                    let has_name = rec.record_type != event::REQUEST_OBJECT_TRANSFER64_LFN;
                    if let Some(obj) = Self::transfer_request(&rec, has_name) {
                        out.push(CameraEvent::ObjectAdded(obj));
                    }
                }
                event::OLC_INFO_CHANGED => {
                    let version = s.values.get(&prop::OLC_INFO_VERSION).copied().unwrap_or(0);
                    if let Some(state) = Self::olc_focus_state(&rec, version) {
                        match state {
                            AfState::Running => s.af_saw_running = true,
                            AfState::Focused => {
                                s.af_outcome.get_or_insert(FocusResult::Focused);
                            }
                            AfState::Failed => {
                                s.af_outcome.get_or_insert(FocusResult::Failed);
                            }
                            AfState::Idle => {}
                        }
                    }
                }
                event::OBJECT_REMOVED => {
                    if let Some(h) = rec.u32_at(8) {
                        out.push(CameraEvent::ObjectRemoved { handle: h });
                    }
                }
                event::PROP_VALUE_CHANGED => {
                    let Some(p) = rec.u32_at(8) else { continue };
                    if rec.bytes.len() >= 16 {
                        if let Some(v) = rec.u32_at(12) {
                            s.values.insert(p, v);
                        }
                    }
                    if p == prop::FOCUS_INFO_EX {
                        if let Some(space) = Self::af_coordinate_space_from(&rec) {
                            s.af_coordinate_space = Some(space);
                        }
                        if Self::focus_info_has_focused_points(&rec) {
                            s.focus_info_reported_focus = true;
                        }
                    }
                    out.push(CameraEvent::PropertyChanged(property_for(p)));
                }
                event::AVAIL_LIST_CHANGED => {
                    let (Some(p), Some(count)) = (rec.u32_at(8), rec.u32_at(16)) else {
                        continue;
                    };
                    let room = rec.bytes.len().saturating_sub(20) / 4;
                    let vals: Vec<u32> = (0..(count as usize).min(room))
                        .filter_map(|i| rec.u32_at(20 + i * 4))
                        .collect();
                    s.available.insert(p, vals);
                    out.push(CameraEvent::PropertyChanged(property_for(p)));
                }
                event::CAMERA_STATUS_CHANGED => {
                    out.push(CameraEvent::CameraBusy(rec.u32_at(8).unwrap_or(0) != 0));
                }
                event::WILL_SOON_SHUTDOWN => {
                    out.push(CameraEvent::Warning(
                        "The camera is about to power off.".into(),
                    ));
                }
                event::STORE_ADDED
                | event::STORE_REMOVED
                | event::STORAGE_INFO_CHANGED
                | event::STORAGE_STATUS_CHANGED => out.push(CameraEvent::StorageChanged),
                event::BULB_EXPOSURE_TIME
                | event::RECORDING_TIME
                | event::AF_RESULT
                | event::SHUTDOWN_TIMER_UPDATED
                | event::REQUEST_GET_EVENT => {}
                other => out.push(CameraEvent::Raw(PtpEvent::new(
                    EventCode(other as u16),
                    [rec.u32_at(8).unwrap_or(0)],
                ))),
            }
        }
        out
    }

    /// FocusInfoEx blob (starts at byte 12 of the record): u32 size, u16
    /// halfsize, u16 version, u16 points, u16 in use, u16 sizeX, u16 sizeY…
    /// (libgphoto2 ptp_unpack_EOS_FocusInfoEx).
    pub fn af_coordinate_space_from(rec: &CanonEventRecord) -> Option<(u32, u32)> {
        let w = rec.u16_at(12 + 12)?;
        let h = rec.u16_at(12 + 14)?;
        (w > 0 && h > 0).then_some((u32::from(w), u32::from(h)))
    }

    pub fn object_added(
        rec: &CanonEventRecord,
        is64: bool,
        _destination: CaptureDestination,
    ) -> Option<NewObject> {
        use object_added_layout as l;
        let handle = rec.u32_at(l::HANDLE).filter(|&h| h != 0)?;
        let storage = rec.u32_at(l::STORAGE_ID).unwrap_or(0);
        let format = ObjectFormat(rec.u16_at(l::FORMAT).unwrap_or(0));
        let (size, parent, name) = if is64 {
            (
                rec.u64_at(l::SIZE64).unwrap_or(0),
                rec.u32_at(l::PARENT64).unwrap_or(0),
                rec.c_string(l::NAME64),
            )
        } else {
            (
                u64::from(rec.u32_at(l::SIZE).unwrap_or(0)),
                rec.u32_at(l::PARENT).unwrap_or(0),
                rec.c_string(l::NAME),
            )
        };
        let mut info = PtpObjectInfo {
            storage_id: storage,
            object_format: format,
            object_compressed_size: size.min(u64::from(u32::MAX)) as u32,
            parent_object: parent,
            filename: name,
            ..Default::default()
        };
        if format.0 == 0 && !info.filename.is_empty() {
            info.object_format = ObjectFormat::UNDEFINED;
        }
        // VERIFY: host-memory objects report storage 0 (or 0x8000xxxx on some bodies).
        let in_ram = storage == 0 || (storage & 0xFFFF_0000) == 0x8000_0000;
        Some(NewObject {
            handle,
            storage_id: storage,
            info: Some(info),
            in_sdram: in_ram,
        })
    }

    pub fn transfer_request(rec: &CanonEventRecord, has_name: bool) -> Option<NewObject> {
        use transfer_request_layout as l;
        let handle = rec.u32_at(l::HANDLE).filter(|&h| h != 0)?;
        let format = ObjectFormat(rec.u16_at(l::FORMAT).unwrap_or(0));
        let size = rec.u32_at(l::SIZE).unwrap_or(0);
        let mut name = if has_name {
            rec.c_string(l::NAME)
        } else {
            String::new()
        };
        if name.is_empty() {
            name = format!(
                "IMG_{:04X}.{}",
                handle & 0xFFFF,
                Self::file_extension(format)
            );
        }
        let info = PtpObjectInfo {
            storage_id: 0,
            object_format: format,
            object_compressed_size: size,
            parent_object: 0,
            filename: name,
            ..Default::default()
        };
        Some(NewObject {
            handle,
            storage_id: 0,
            info: Some(info),
            in_sdram: true,
        })
    }

    /// Extension for a nameless capture, from its object format (libgphoto2 PTP_OFC_CANON_*).
    pub fn file_extension(format: ObjectFormat) -> &'static str {
        match format.0 {
            0xB108 => "CR3",
            0xB101 | 0xB103 => "CR2",
            0xB10A | 0xB110 => "HIF", // VERIFY: Canon HEIF format code
            _ => "JPG",
        }
    }

    // MARK: Properties

    /// Descriptor from the cache alone (no camera round trip).
    pub fn descriptor(&self, p: TetherProperty, code: u32, value: u32) -> PropertyDescriptor {
        let writable = self
            .capabilities
            .contains(CameraCapabilities::PROPERTY_CONTROL)
            && !READ_ONLY.contains(&code);
        let available = self.available(code).unwrap_or_default();
        let mut choices: Vec<PropertyChoice> = available
            .iter()
            .map(|&v| PropertyChoice::new(PtpValue::UInt32(v), display(code, v)))
            .collect();
        if code == prop::CAPTURE_DESTINATION && choices.is_empty() {
            let mut allowed = vec![prop::DESTINATION_CARD];
            if self
                .capabilities
                .contains(CameraCapabilities::SDRAM_CAPTURE)
            {
                allowed.extend([prop::DESTINATION_HOST, prop::DESTINATION_BOTH]);
            }
            choices = allowed
                .into_iter()
                .map(|v| PropertyChoice::new(PtpValue::UInt32(v), display(code, v)))
                .collect();
        }
        let form = if choices.is_empty() {
            PropertyForm::Other
        } else {
            PropertyForm::Choices(choices)
        };
        PropertyDescriptor::new(
            p,
            PtpValue::UInt32(value),
            display(code, value),
            writable,
            form,
        )
    }

    /// SetDevicePropValueEx payload: UInt32 size (12), UInt32 propCode, UInt32 value.
    pub fn set_property_payload(code: u32, value: u32) -> Vec<u8> {
        let mut b = ByteBuffer::new();
        b.write_u32(12);
        b.write_u32(code);
        b.write_u32(value);
        b.into_bytes()
    }

    pub async fn set_eos_property(&self, code: u32, value: u32) -> PtpResult<()> {
        if !self.info.supports_op(op::SET_DEVICE_PROP_VALUE_EX) {
            return Err(PtpError::Unsupported(
                "This Canon does not allow setting properties over PTP.".into(),
            ));
        }
        run_out(
            &self.engine,
            op::SET_DEVICE_PROP_VALUE_EX,
            &[],
            Self::set_property_payload(code, value),
        )
        .await?;
        lock(&self.state).values.insert(code, value);
        Ok(())
    }

    // MARK: Transfer

    /// 1 MB GetPartialObject reads, as libgphoto2 does: "the EOS R does not
    /// like 5MB", and Canon's own 0x9107 is suspected of crashing newer bodies.
    /// 0x9107 is kept only for bodies without the standard operation.
    async fn download_from_memory(
        &self,
        handle: u32,
        total: u32,
        progress: Option<&ProgressFn>,
    ) -> PtpResult<Vec<u8>> {
        let opc = if self.info.supports_op(OperationCode::GET_PARTIAL_OBJECT) {
            OperationCode::GET_PARTIAL_OBJECT
        } else {
            op::GET_PARTIAL_OBJECT_EX
        };
        let chunk: u32 = 1 << 20;
        let mut out = Vec::with_capacity(total as usize);
        let mut offset: u32 = 0;
        while offset < total {
            let want = chunk.min(total - offset);
            let r = run(&self.engine, opc, &[handle, offset, want], Some(20.0), true).await?;
            if r.data_in.is_empty() {
                return Err(PtpError::Malformed(format!(
                    "The camera sent no data at byte {offset} of {total}."
                )));
            }
            out.extend_from_slice(&r.data_in);
            offset = offset.saturating_add(u32::try_from(r.data_in.len()).unwrap_or(u32::MAX));
            if let Some(p) = progress {
                p(out.len(), Some(total as usize));
            }
        }
        Ok(out)
    }

    async fn finish_transfer(&self, handle: u32) {
        if !self.info.supports_op(op::TRANSFER_COMPLETE) {
            return;
        }
        fire(&self.engine, op::TRANSFER_COMPLETE, &[handle], 5.0).await;
    }

    // MARK: Touch AF
    //
    // How Canon's own software handles AF: EOS Utility has AF ON / OFF
    // buttons and AF "continues until you click OFF"; Camera Connect's AF
    // button is a half-press. Servo never "finishes" (bodies don't even
    // confirm focus in Servo), so nothing here guesses with a timer:
    //  - a tap focuses once and stops on the camera's own lock / fail
    //    report (OLCInfoChanged focus info; FocusInfoEx in-focus points as
    //    a fallback). In Servo / AI Focus the tap runs in One Shot so there
    //    is a lock to wait for; the user's mode comes back as soon as it lands.
    //  - press and hold tracks in the user's own mode (AF ON) until the
    //    finger lifts (AF OFF), like EOS Utility.

    /// The body reports AF state through OLC events (needs the request op
    /// and a known layout version).
    pub fn olc_focus_available(&self) -> bool {
        self.info.supports_op(op::SET_REQUEST_OLC_INFO_GROUP)
            && self.value(prop::OLC_INFO_VERSION).unwrap_or(0) >= 7
    }

    fn tracks_continuously(&self) -> bool {
        matches!(
            self.value(prop::FOCUS_MODE),
            Some(FOCUS_MODE_SERVO) | Some(FOCUS_MODE_AI_FOCUS)
        )
    }

    async fn move_af_point(&self, nx: f64, ny: f64) -> PtpResult<()> {
        // VERIFY: fallback space when the body has not sent FocusInfoEx yet
        // (EOS R full-sensor AF coordinates).
        let (w, h) = self.af_coordinate_space().unwrap_or((8192, 5464));
        let x = (nx.clamp(0.0, 1.0) * f64::from(w - 1)) as u32;
        let y = (ny.clamp(0.0, 1.0) * f64::from(h - 1)) as u32;
        run(
            &self.engine,
            op::TOUCH_AF_POSITION,
            &[TOUCH_AF_TYPE, x, y],
            None,
            false,
        )
        .await
        .map(|_| ())
    }

    /// DoAf, then poll until the body says focused or failed. The limit only
    /// covers a body that never reports; it doesn't decide focus.
    async fn run_af_until_reported(&self) -> PtpResult<FocusResult> {
        if let Ok(events) = self.fetch_events().await {
            self.push_pending(events); // stale state out
        }
        {
            let mut s = lock(&self.state);
            s.af_outcome = None;
            s.af_saw_running = false;
            s.focus_info_reported_focus = false;
        }
        run(&self.engine, op::DO_AF, &[], Some(10.0), false).await?;
        let olc = self.olc_focus_available();
        let limit = if olc {
            Self::TOUCH_AF_REPORT_TIMEOUT
        } else {
            Self::TOUCH_AF_FALLBACK_TIME
        };
        let started = Instant::now();
        while started.elapsed() < limit {
            if let Ok(events) = self.fetch_events().await {
                self.push_pending(events);
            }
            {
                let s = lock(&self.state);
                if let Some(outcome) = s.af_outcome {
                    return Ok(outcome);
                }
                // Without OLC, FocusInfoEx listing in-focus points is libgphoto2's cue.
                if !olc && s.focus_info_reported_focus {
                    return Ok(FocusResult::Focused);
                }
            }
            tokio::time::sleep(Duration::from_millis(80)).await;
        }
        Ok(FocusResult::Unconfirmed)
    }

    /// OLC focus info: byte 4 is the result (1 focused, 2 failed), byte 5 is
    /// "AF running" (libgphoto2 ptp-pack.c, mask 0x0100).
    pub fn olc_focus_state(rec: &CanonEventRecord, version: u32) -> Option<AfState> {
        if version < 7 {
            return None;
        }
        let row = OLC_SIZES[(version as usize).min(OLC_SIZES.len() - 1)];
        if row.len() != 13 {
            return None;
        }
        let mask = rec.u16_at(12)?;
        if mask & OLC_FOCUS_INFO_MASK == 0 {
            return None;
        }
        let mut offset = 16usize;
        for (bit, size) in row.iter().enumerate().take(8) {
            if mask & (1 << bit) != 0 {
                offset += size;
            }
        }
        if offset + 5 >= rec.bytes.len() {
            return None;
        }
        let result = rec.bytes[offset + 4];
        let running = rec.bytes[offset + 5];
        Some(match result {
            1 => AfState::Focused,
            2 => AfState::Failed,
            _ if running != 0 => AfState::Running,
            _ => AfState::Idle,
        })
    }

    /// FocusInfoEx (blob at record byte 12): after the point table comes a
    /// bitmask of the points AF settled on; libgphoto2 reads "none" as not
    /// in focus.
    pub fn focus_info_has_focused_points(rec: &CanonEventRecord) -> bool {
        let base = 12;
        let (Some(in_struct), Some(in_use)) = (rec.u16_at(base + 8), rec.u16_at(base + 10)) else {
            return false;
        };
        if in_struct == 0 || in_use == 0 || in_use > in_struct {
            return false;
        }
        let mask_start = base + 20 + usize::from(in_struct) * 8;
        for i in 0..usize::from(in_use) {
            let byte = mask_start + i / 8;
            let Some(&b) = rec.bytes.get(byte) else {
                return false;
            };
            if b & (1 << (i % 8)) != 0 {
                return true;
            }
        }
        false
    }

    async fn use_one_shot_for_touch_af(&self) {
        let Some(mode) = self.value(prop::FOCUS_MODE) else {
            return;
        };
        if !(mode == FOCUS_MODE_SERVO || mode == FOCUS_MODE_AI_FOCUS)
            || !self
                .capabilities
                .contains(CameraCapabilities::PROPERTY_CONTROL)
        {
            return;
        }
        match self
            .set_eos_property(prop::FOCUS_MODE, FOCUS_MODE_ONE_SHOT)
            .await
        {
            Ok(()) => {
                lock(&self.state)
                    .focus_mode_before_touch
                    .get_or_insert(mode);
                tracing::info!("[Canon] touch AF: One Shot for the tap (was {mode})");
            }
            Err(e) => {
                // Body won't switch (mode locked): the tap runs in Servo and is
                // stopped once the camera has reported.
                tracing::info!("[Canon] touch AF: couldn't switch to One Shot: {e}");
            }
        }
    }

    /// Puts the user's AF mode back, unless they changed it on the body meanwhile.
    pub async fn restore_focus_mode_after_touch(&self) {
        let mode = {
            let mut s = lock(&self.state);
            let Some(mode) = s.focus_mode_before_touch.take() else {
                return;
            };
            if s.values.get(&prop::FOCUS_MODE) != Some(&FOCUS_MODE_ONE_SHOT) {
                return;
            }
            mode
        };
        let _ = self.set_eos_property(prop::FOCUS_MODE, mode).await;
        tracing::info!("[Canon] touch AF: restored AF mode {mode}");
    }

    async fn touch_focus_inner(&self, nx: f64, ny: f64) -> PtpResult<FocusResult> {
        self.move_af_point(nx, ny).await?;
        if !self.info.supports_op(op::DO_AF) {
            return Ok(FocusResult::Unconfirmed);
        }
        let result = self.run_af_until_reported().await?;
        tracing::info!("[Canon] touch AF: {}", result.raw());
        // Still tracking (the switch to One Shot was refused): stop it now
        // that the camera has had its say, so the lens doesn't keep hunting.
        let before_is_none = lock(&self.state).focus_mode_before_touch.is_none();
        if before_is_none && self.tracks_continuously() && self.info.supports_op(op::AF_CANCEL) {
            fire(&self.engine, op::AF_CANCEL, &[], 5.0).await;
        }
        Ok(result)
    }

    /// GetViewFinderData payload is a record stream (UInt32 size, UInt32 type,
    /// payload); the JPEG is the record of type 1. Falls back to scanning
    /// for the SOI marker.
    pub fn view_finder_jpeg(data: &[u8]) -> Option<Vec<u8>> {
        let mut pos = 0usize;
        while pos + 8 <= data.len() {
            let size = u32::from_le_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]])
                as usize;
            let kind =
                u32::from_le_bytes([data[pos + 4], data[pos + 5], data[pos + 6], data[pos + 7]]);
            if size < 8 || pos + size > data.len() {
                break;
            }
            if kind == VIEW_FINDER_JPEG_RECORD {
                let payload = &data[pos + 8..pos + size];
                return Some(jpeg_payload(payload).unwrap_or(payload).to_vec());
            }
            pos += size;
        }
        jpeg_payload(data).map(<[u8]>::to_vec)
    }
}

#[async_trait]
impl VendorHandler for CanonHandler {
    fn vendor(&self) -> CameraVendor {
        CameraVendor::Canon
    }

    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities
    }

    fn event_poll_interval(&self) -> Duration {
        Duration::from_millis(200)
    }

    // MARK: Gate

    async fn prepare(&self) -> PtpResult<()> {
        if !self.info.supports_op(op::SET_REMOTE_MODE) {
            return Err(PtpError::VendorGate(
                "This Canon does not offer PC remote mode over this connection.".into(),
            ));
        }
        run(&self.engine, op::SET_REMOTE_MODE, &[1], None, false).await?;
        if self.info.supports_op(op::SET_EVENT_MODE) {
            run(&self.engine, op::SET_EVENT_MODE, &[1], None, false).await?;
        }
        // OLC events carry the live AF state touch focus waits on.
        if self.info.supports_op(op::SET_REQUEST_OLC_INFO_GROUP) {
            let _ = self
                .engine
                .execute(PtpRequest::new(op::SET_REQUEST_OLC_INFO_GROUP, [0x1FFF]))
                .await;
        }
        // The first dump carries every property and its allowed values.
        self.fetch_events().await?;
        Ok(())
    }

    async fn teardown(&self) {
        self.stop_live_view().await;
        if self.info.supports_op(op::SET_EVENT_MODE) {
            let _ = self
                .engine
                .execute(PtpRequest::new(op::SET_EVENT_MODE, [0]))
                .await;
        }
        let _ = self
            .engine
            .execute(PtpRequest::new(op::SET_REMOTE_MODE, [0]))
            .await;
    }

    // MARK: Capture

    async fn set_capture_destination(&self, d: CaptureDestination) -> PtpResult<()> {
        let sdram = self
            .capabilities
            .contains(CameraCapabilities::SDRAM_CAPTURE);
        let refuse = || {
            PtpError::Unsupported("This Canon cannot keep captures in memory for transfer.".into())
        };
        let value = match d {
            CaptureDestination::Card => prop::DESTINATION_CARD,
            CaptureDestination::Host if sdram => prop::DESTINATION_HOST,
            CaptureDestination::Both if sdram => prop::DESTINATION_BOTH,
            _ => return Err(refuse()),
        };
        self.set_eos_property(prop::CAPTURE_DESTINATION, value)
            .await?;
        lock(&self.state).destination = d;
        self.report_host_capacity().await
    }

    async fn capture(&self, autofocus: bool) -> PtpResult<()> {
        self.restore_focus_mode_after_touch().await;
        if self.info.supports_op(op::REMOTE_RELEASE_ON) {
            // VERIFY: libgphoto2 camera_canon_eos_capture — RemoteReleaseOn(1,0)
            // half-press, (2,0) full press, RemoteReleaseOff(2) then (1).
            // Without AF libgphoto2 sends 3 (full press, no AF) on both.
            // Drain queued events first: EOS bodies report busy while their
            // event queue is full (common right after connecting).
            if let Ok(events) = self.fetch_events().await {
                self.push_pending(events);
            }
            // Re-assert the host's free space: bodies forget it (sleep, card swap).
            let _ = self.report_host_capacity().await;
            match self.two_stage_capture(autofocus).await {
                Err(e) if Self::is_busy(&e) => Err(PtpError::VendorGate(
                    "The camera won't fire. Check a lens is attached and focused, the camera isn't showing a menu or playback, and the card isn't full.".into(),
                )),
                other => other,
            }
        } else if self.info.supports_op(op::REMOTE_RELEASE) {
            run(&self.engine, op::REMOTE_RELEASE, &[], Some(15.0), false)
                .await
                .map(|_| ())
        } else {
            Err(PtpError::Unsupported(
                "This Canon does not support remote capture over PTP.".into(),
            ))
        }
    }

    // MARK: Events

    async fn poll_events(&self) -> PtpResult<Vec<CameraEvent>> {
        let mut out = std::mem::take(&mut lock(&self.state).pending);
        out.extend(self.fetch_events().await?);
        Ok(out)
    }

    async fn translate(&self, e: &PtpEvent) -> Option<CameraEvent> {
        let first = e.parameters.first().copied();
        match u32::from(e.code.0) {
            event::REQUEST_GET_EVENT => {
                // The camera asks us to poll; the next poll_events does.
                None
            }
            event::REQUEST_OBJECT_TRANSFER
            | event::REQUEST_OBJECT_TRANSFER64
            | event::REQUEST_OBJECT_TRANSFER64_LFN => first.map(|h| {
                CameraEvent::ObjectAdded(NewObject {
                    in_sdram: true,
                    ..NewObject::new(h)
                })
            }),
            event::OBJECT_ADDED_EX | event::OBJECT_ADDED_EX64 => {
                if self.destination() != CaptureDestination::Card {
                    return None;
                }
                first.map(|h| CameraEvent::ObjectAdded(NewObject::new(h)))
            }
            event::PROP_VALUE_CHANGED | event::AVAIL_LIST_CHANGED => {
                Some(CameraEvent::PropertyChanged(first.and_then(property_for)))
            }
            event::CAMERA_STATUS_CHANGED => Some(CameraEvent::CameraBusy(first.unwrap_or(0) != 0)),
            event::WILL_SOON_SHUTDOWN => Some(CameraEvent::Warning(
                "The camera is about to power off.".into(),
            )),
            _ => self.generic.translate(e).await,
        }
    }

    // MARK: Properties

    async fn read_properties(
        &self,
        properties: &[TetherProperty],
    ) -> PtpResult<Vec<PropertyDescriptor>> {
        // Refresh the caches; events seen here are handed to the next poll.
        let events = self.fetch_events().await?;
        self.push_pending(events);
        let mut out = Vec::new();
        for &p in properties {
            let Some(code) = code_for(p) else { continue };
            let Some(v) = self.value(code) else { continue };
            out.push(self.descriptor(p, code, v));
        }
        Ok(out)
    }

    async fn write_property(&self, property: TetherProperty, raw: PtpValue) -> PtpResult<()> {
        let Some(code) = code_for(property).filter(|c| !READ_ONLY.contains(c)) else {
            return Err(cannot_set(property));
        };
        let Some(v) = raw.uint_value() else {
            return Err(needs_numeric(property));
        };
        let v = v as u32;
        self.set_eos_property(code, v).await?;
        if code == prop::CAPTURE_DESTINATION {
            lock(&self.state).destination = match v {
                prop::DESTINATION_HOST => CaptureDestination::Host,
                prop::DESTINATION_BOTH => CaptureDestination::Both,
                _ => CaptureDestination::Card,
            };
        }
        Ok(())
    }

    // MARK: Transfer

    async fn fetch_object(
        &self,
        object: &NewObject,
        progress: Option<ProgressFn>,
    ) -> PtpResult<(PtpObjectInfo, Vec<u8>)> {
        if !object.in_sdram || !self.info.supports_op(op::GET_PARTIAL_OBJECT_EX) {
            return self.generic.fetch_object(object, progress).await;
        }
        let mut oi = object.info.clone();
        if oi.as_ref().is_none_or(|i| i.object_compressed_size == 0) {
            // Memory objects often refuse GetObjectInfo; a short timeout keeps
            // a refusal from stalling the queue.
            let req = PtpRequest::new(OperationCode::GET_OBJECT_INFO, [object.handle])
                .with_timeout(Duration::from_secs(5));
            if let Ok(r) = self.engine.execute(req).await {
                if let Ok(fetched) = PtpObjectInfo::parse(&r.data_in) {
                    oi = Some(fetched);
                }
            }
        }
        let Some(info_out) = oi.filter(|i| i.object_compressed_size > 0) else {
            self.finish_transfer(object.handle).await;
            return Err(PtpError::Malformed(format!(
                "The camera didn't say how big capture {} is.",
                object.handle
            )));
        };
        let total = info_out.object_compressed_size;
        tracing::info!(
            "[Canon] transfer {:x} {} {} bytes",
            object.handle,
            info_out.filename,
            total
        );
        match self
            .download_from_memory(object.handle, total, progress.as_ref())
            .await
        {
            Ok(data) => {
                self.finish_transfer(object.handle).await;
                tracing::info!("[Canon] transfer {:x} done", object.handle);
                Ok((info_out, data))
            }
            Err(e) => {
                // Even a failed transfer must be closed, or the body holds the
                // card and stays busy until it is switched off.
                tracing::info!("[Canon] transfer {:x} failed: {e}", object.handle);
                self.finish_transfer(object.handle).await;
                Err(e)
            }
        }
    }

    // MARK: Live view

    async fn start_live_view(&self, _quality: LiveViewQuality) -> PtpResult<()> {
        if !self.capabilities.contains(CameraCapabilities::LIVE_VIEW) {
            return Err(no_live_view());
        }
        self.set_eos_property(prop::EVF_MODE, 1).await?;
        self.set_eos_property(prop::EVF_OUTPUT_DEVICE, prop::EVF_OUTPUT_PC)
            .await?;
        let need_space = {
            let mut s = lock(&self.state);
            s.live_view_on = true;
            s.live_view_started = Instant::now();
            s.live_view_has_frame = false;
            s.af_coordinate_space.is_none()
        };
        // Ask for FocusInfoEx so touch AF knows the coordinate space.
        if need_space && self.info.supports_op(op::REQUEST_DEVICE_PROP_VALUE) {
            let _ = self
                .engine
                .execute(PtpRequest::new(
                    op::REQUEST_DEVICE_PROP_VALUE,
                    [prop::FOCUS_INFO_EX],
                ))
                .await;
            if let Ok(events) = self.fetch_events().await {
                self.push_pending(events);
            }
        }
        Ok(())
    }

    async fn stop_live_view(&self) {
        {
            let mut s = lock(&self.state);
            if !s.live_view_on {
                return;
            }
            s.live_view_on = false;
        }
        self.stop_tracking_focus().await;
        self.restore_focus_mode_after_touch().await;
        let _ = self
            .set_eos_property(prop::EVF_OUTPUT_DEVICE, prop::EVF_OUTPUT_OFF)
            .await;
    }

    async fn next_live_view_frame(&self) -> PtpResult<Option<LiveViewFrame>> {
        if !lock(&self.state).live_view_on {
            return Ok(None);
        }
        let req = PtpRequest::new(op::GET_VIEW_FINDER_DATA, [VIEW_FINDER_PARAM])
            .expecting_large_data(true)
            .with_timeout(Duration::from_secs(5))
            .retrying_busy(false);
        let r = self.engine.execute(req).await?;
        match r.code {
            ResponseCode::OK => {}
            ResponseCode::DEVICE_BUSY | ResponseCode::ACCESS_DENIED | NOT_READY => {
                // Frame not ready yet; but a body that never sends one gets a
                // reason, not an endless spinner.
                let s = lock(&self.state);
                if !s.live_view_has_frame
                    && s.live_view_started.elapsed() > Self::LIVE_VIEW_START_TIMEOUT
                {
                    return Err(PtpError::VendorGate(
                        "The camera isn't sending live view. Check a lens is attached and the camera is on its shooting screen, not a menu or playback.".into(),
                    ));
                }
                return Ok(None);
            }
            code => {
                return Err(PtpError::Response {
                    op: op::GET_VIEW_FINDER_DATA,
                    code,
                    parameters: r.parameters,
                })
            }
        }
        let Some(jpeg) = Self::view_finder_jpeg(&r.data_in) else {
            return Ok(None);
        };
        let mut s = lock(&self.state);
        s.live_view_has_frame = true;
        s.frame_sequence += 1;
        Ok(Some(live_frame(jpeg, s.frame_sequence)))
    }

    // MARK: Touch AF

    async fn focus(&self, x: f64, y: f64) -> PtpResult<FocusResult> {
        if !self
            .capabilities
            .contains(CameraCapabilities::TOUCH_AUTOFOCUS)
        {
            return Err(PtpError::Unsupported(
                "Touch focus is not available on this camera.".into(),
            ));
        }
        if lock(&self.state).tracking_focus {
            self.stop_tracking_focus().await;
        }
        self.use_one_shot_for_touch_af().await;
        let result = self.touch_focus_inner(x, y).await;
        self.restore_focus_mode_after_touch().await;
        result
    }

    /// AF ON at a point, in the user's own AF mode, until `stop_tracking_focus`.
    async fn start_tracking_focus(&self, x: f64, y: f64) -> PtpResult<()> {
        if !self
            .capabilities
            .contains(CameraCapabilities::TOUCH_AUTOFOCUS)
            || !self.info.supports_op(op::DO_AF)
        {
            return Err(PtpError::Unsupported(
                "Touch focus is not available on this camera.".into(),
            ));
        }
        self.restore_focus_mode_after_touch().await;
        self.move_af_point(x, y).await?;
        run(&self.engine, op::DO_AF, &[], Some(10.0), false).await?;
        lock(&self.state).tracking_focus = true;
        tracing::info!("[Canon] touch AF: tracking");
        Ok(())
    }

    /// AF OFF.
    async fn stop_tracking_focus(&self) {
        {
            let mut s = lock(&self.state);
            if !s.tracking_focus {
                return;
            }
            s.tracking_focus = false;
        }
        if self.info.supports_op(op::AF_CANCEL) {
            fire(&self.engine, op::AF_CANCEL, &[], 5.0).await;
        }
        tracing::info!("[Canon] touch AF: tracking stopped");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposure_compensation_table() {
        assert_eq!(exposure_compensation(0x03), "+1/3");
        assert_eq!(exposure_compensation(0x04), "+1/2");
        assert_eq!(exposure_compensation(0x05), "+2/3");
        assert_eq!(exposure_compensation(0x08), "+1");
        assert_eq!(exposure_compensation(0x10), "+2");
        assert_eq!(exposure_compensation(0xFD), "-1/3");
        assert_eq!(exposure_compensation(0xF0), "-2");
        assert_eq!(exposure_compensation(0x18), "+3");
        assert_eq!(exposure_compensation(0x01), "+1/8");
    }

    #[test]
    fn property_code_mapping_round_trips() {
        for p in TetherProperty::ALL {
            if let Some(c) = code_for(p) {
                assert_eq!(property_for(c), Some(p), "{p:?}");
            }
        }
        assert_eq!(property_for(prop::OLC_INFO_VERSION), None);
    }

    #[test]
    fn record_parser_rejects_oversized_and_tiny_records() {
        // size 4 (< 8): stop.
        assert!(CanonEventRecord::parse(&[4, 0, 0, 0, 1, 0, 0, 0]).is_empty());
        // size past the end: stop.
        assert!(CanonEventRecord::parse(&[16, 0, 0, 0, 1, 0, 0, 0, 0]).is_empty());
        let r = CanonEventRecord {
            record_type: 1,
            bytes: vec![0; 10],
        };
        assert_eq!(r.u32_at(8), None);
        assert_eq!(r.u16_at(8), Some(0));
        assert_eq!(r.u64_at(usize::MAX), None);
        assert_eq!(r.c_string(20), "");
    }
}
