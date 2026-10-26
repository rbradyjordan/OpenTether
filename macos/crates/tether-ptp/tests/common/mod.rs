//! Port of `VendorTestSupport.swift`: one DeviceInfo fixture per vendor,
//! listing the operations a real body of that brand advertises, so
//! capabilities derive from runtime flags; plus the connected rig.
#![allow(dead_code)]

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use tether_ptp::ptp::*;
use tether_ptp::testing::ScriptedTransport;
use tether_types::TransportKind;

pub const STANDARD_OPS: [OperationCode; 13] = [
    OperationCode::GET_DEVICE_INFO,
    OperationCode::OPEN_SESSION,
    OperationCode::CLOSE_SESSION,
    OperationCode::GET_STORAGE_IDS,
    OperationCode::GET_STORAGE_INFO,
    OperationCode::GET_OBJECT_HANDLES,
    OperationCode::GET_OBJECT_INFO,
    OperationCode::GET_OBJECT,
    OperationCode::GET_PARTIAL_OBJECT,
    OperationCode::GET_THUMB,
    OperationCode::GET_DEVICE_PROP_DESC,
    OperationCode::GET_DEVICE_PROP_VALUE,
    OperationCode::SET_DEVICE_PROP_VALUE,
];

pub const STANDARD_PROPS: [DevicePropCode; 6] = [
    DevicePropCode::F_NUMBER,
    DevicePropCode::EXPOSURE_TIME,
    DevicePropCode::EXPOSURE_INDEX,
    DevicePropCode::EXPOSURE_BIAS_COMPENSATION,
    DevicePropCode::WHITE_BALANCE,
    DevicePropCode::BATTERY_LEVEL,
];

pub fn info_full(
    manufacturer: &str,
    model: &str,
    ops: &[u16],
    props: &[u16],
    extra_standard_props: bool,
    vendor_extension: u32,
) -> PtpDeviceInfo {
    let mut operations: Vec<OperationCode> = STANDARD_OPS.to_vec();
    operations.extend(ops.iter().map(|o| OperationCode(*o)));
    let mut properties: Vec<DevicePropCode> = if extra_standard_props {
        STANDARD_PROPS.to_vec()
    } else {
        Vec::new()
    };
    properties.extend(props.iter().map(|p| DevicePropCode(*p)));
    PtpDeviceInfo {
        vendor_extension_id: vendor_extension,
        operations_supported: operations,
        events_supported: vec![
            EventCode::OBJECT_ADDED,
            EventCode::DEVICE_PROP_CHANGED,
            EventCode::CAPTURE_COMPLETE,
        ],
        device_properties_supported: properties,
        capture_formats: vec![ObjectFormat::EXIF_JPEG],
        image_formats: vec![ObjectFormat::EXIF_JPEG],
        manufacturer: manufacturer.into(),
        model: model.into(),
        device_version: "1.0".into(),
        serial_number: "SN123".into(),
        ..Default::default()
    }
}

pub fn info(manufacturer: &str, model: &str, ops: &[u16]) -> PtpDeviceInfo {
    info_full(manufacturer, model, ops, &[], true, 0)
}

pub fn canon() -> PtpDeviceInfo {
    info_full(
        "Canon Inc.",
        "Canon EOS R5",
        &[
            0x9114, 0x9115, 0x9116, 0x9110, 0x9128, 0x9129, 0x9107, 0x9117, 0x9153, 0x910F,
        ],
        &[],
        false,
        0x0B,
    )
}

pub fn canon_old() -> PtpDeviceInfo {
    info_full(
        "Canon Inc.",
        "Canon EOS 5D Mark II",
        &[0x9114, 0x9115, 0x9116, 0x9110, 0x910F, 0x9107, 0x9117],
        &[],
        false,
        0x0B,
    )
}

/// An EOS R5 Mark II as it is expected to present itself: two-stage
/// shutter, SDRAM transfer, PC HDD capacity, live view, touch AF, OLC events.
pub fn canon_r5_mark_ii() -> PtpDeviceInfo {
    info_full(
        "Canon Inc.",
        "Canon EOS R5m2",
        &[
            0x9114, 0x9115, 0x9116, 0x9110, 0x9128, 0x9129, 0x9107, 0x9117, 0x9153, 0x910F, 0x915B,
            0x9154, 0x9160, 0x913D, 0x911A, 0x9127,
        ],
        &[],
        false,
        0x0B,
    )
}

pub fn nikon_z() -> PtpDeviceInfo {
    info_full(
        "Nikon Corporation",
        "Z 6_2",
        &[
            0x9038, 0x90C8, 0x90C7, 0x90C0, 0x90CB, 0x9207, 0x9201, 0x9202, 0x9203,
        ],
        &[0xD100, 0xD1A2, 0xD1A4],
        true,
        0x0A,
    )
}

pub fn nikon_d() -> PtpDeviceInfo {
    info_full(
        "Nikon Corporation",
        "D850",
        &[
            0x90C2, 0x90C8, 0x90C7, 0x90C0, 0x90CB, 0x9207, 0x9201, 0x9202, 0x9203, 0x100E,
        ],
        &[0xD100, 0xD1A4],
        true,
        0x0A,
    )
}

pub fn sony() -> PtpDeviceInfo {
    let mut ops = STANDARD_OPS.to_vec();
    ops.extend(
        [0x9201u16, 0x9202, 0x9205, 0x9207, 0x9209]
            .iter()
            .map(|o| OperationCode(*o)),
    );
    PtpDeviceInfo {
        vendor_extension_id: 0x11,
        operations_supported: ops,
        events_supported: vec![EventCode(0xC201), EventCode(0xC203)],
        device_properties_supported: vec![],
        capture_formats: vec![ObjectFormat::EXIF_JPEG],
        image_formats: vec![ObjectFormat::EXIF_JPEG],
        manufacturer: "Sony Corporation".into(),
        model: "ILCE-7M4".into(),
        device_version: "2.00".into(),
        serial_number: "00001".into(),
        ..Default::default()
    }
}

pub fn sony_mass_storage() -> PtpDeviceInfo {
    info_full("Sony Corporation", "ILCE-7M4", &[], &[], false, 0x11)
}

pub fn fuji() -> PtpDeviceInfo {
    info_full(
        "FUJIFILM",
        "X-T5",
        &[0x100E],
        &[0xD207, 0xD212, 0xD001, 0xD018],
        true,
        0x0E,
    )
}

pub fn olympus() -> PtpDeviceInfo {
    info_full(
        "OLYMPUS",
        "E-M1MarkIII",
        &[0x9481, 0x9484],
        &[0xD052],
        true,
        0x06,
    )
}

pub fn panasonic() -> PtpDeviceInfo {
    info_full(
        "Panasonic",
        "DC-S5",
        &[0x9402, 0x9403, 0x9404, 0x9412, 0x9706],
        &[],
        false,
        0x1C,
    )
}

pub fn leica() -> PtpDeviceInfo {
    info_full(
        "Leica Camera AG",
        "SL2",
        &[0x9001, 0x9002, 0x9003, 0x9004, 0x9005, 0x9006],
        &[],
        true,
        0x1E,
    )
}

/// A connected engine + scripted transport for a fixture.
pub struct Rig {
    pub transport: Arc<ScriptedTransport>,
    pub engine: Arc<PtpEngine>,
    pub info: PtpDeviceInfo,
}

impl Rig {
    pub async fn new(info: PtpDeviceInfo) -> Self {
        let transport = ScriptedTransport::new(TransportKind::Usb, info.clone());
        let engine = Arc::new(PtpEngine::new(transport.clone()));
        // Busy paths are tested; don't sit through the engine's backoff.
        engine.set_retry_busy_attempts(0);
        engine.connect(1).await.unwrap();
        Self {
            transport,
            engine,
            info,
        }
    }

    /// Requests after the connect handshake (GetDeviceInfo, OpenSession).
    pub fn requests(&self) -> Vec<PtpRequest> {
        self.transport.requests().into_iter().skip(2).collect()
    }

    pub fn codes(&self) -> Vec<OperationCode> {
        self.requests().into_iter().map(|r| r.code).collect()
    }

    pub fn params(&self) -> Vec<Vec<u32>> {
        self.requests().into_iter().map(|r| r.parameters).collect()
    }
}

/// An unconnected engine for constructor-only tests.
pub fn idle_engine(info: &PtpDeviceInfo) -> Arc<PtpEngine> {
    Arc::new(PtpEngine::new(ScriptedTransport::new(
        TransportKind::Usb,
        info.clone(),
    )))
}

/// Canned DevicePropDesc for scripted GetDevicePropDesc.
pub fn prop_desc(
    code: DevicePropCode,
    data_type: DataType,
    current: i64,
    choices: &[i64],
    writable: bool,
) -> Vec<u8> {
    PtpDevicePropDesc {
        code,
        data_type,
        is_writable: writable,
        factory_default: PtpValue::make(data_type, current),
        current: PtpValue::make(data_type, current),
        form: PropForm::Enumeration(
            choices
                .iter()
                .map(|c| PtpValue::make(data_type, *c))
                .collect(),
        ),
    }
    .encoded()
}

pub fn handles(h: &[u32]) -> Vec<u8> {
    let mut b = ByteBuffer::new();
    b.write_u32_array(h);
    b.into_bytes()
}

#[derive(Default)]
pub struct Counter(AtomicUsize);

impl Counter {
    pub fn increment(&self) -> usize {
        self.0.fetch_add(1, Ordering::SeqCst) + 1
    }
    pub fn value(&self) -> usize {
        self.0.load(Ordering::SeqCst)
    }
}
