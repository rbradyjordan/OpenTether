//! Fujifilm X / GFX: tether priority gate, standard capture, CurrentState
//! property events, object-handle diff for new files (RAW+JPEG arrive as
//! two objects). Ported from `FujifilmHandler.swift`.
//!
//! Fuji control is mostly standard PTP; the extras are properties
//! (libgphoto2 `PTP_DPC_FUJI_*`). VERIFY marks the unconfirmed ones.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tether_types::{CameraCapabilities, CameraVendor, CaptureDestination};

use super::{cannot_set, run};
use crate::device::property::format;
use crate::device::{
    vendor_props, CameraEvent, GenericPtpHandler, NewObject, ObjectHandleDiffer,
    PropertyDescriptor, TetherProperty, VendorHandler,
};
use crate::ptp::transport::lock;
use crate::ptp::{
    ByteBuffer, DevicePropCode, EventCode, OperationCode, ProgressFn, PtpDeviceInfo, PtpEngine,
    PtpError, PtpEvent, PtpObjectInfo, PtpResult, PtpValue,
};

/// Fujifilm operation codes.
pub mod op {
    use crate::ptp::OperationCode as O;
    /// VERIFY: libgphoto2 PTP_OC_FUJI_GetDeviceInfo neighbours.
    pub const GET_OBJECT_INFO_EX: O = O(0x900C);
    /// VERIFY
    pub const GET_DEVICE_INFO: O = O(0x900C);
}

/// Fujifilm device property codes.
pub mod prop {
    use crate::ptp::DevicePropCode as P;
    /// VERIFY: libgphoto2 PTP_DPC_FUJI_FilmSimulation.
    pub const FILM_SIMULATION: P = P(0xD001);
    /// VERIFY: libgphoto2 PTP_DPC_FUJI_Quality.
    pub const IMAGE_QUALITY: P = P(0xD018);
    /// VERIFY
    pub const RELEASE_MODE: P = P(0xD201);
    /// VERIFY: libgphoto2 PTP_DPC_FUJI_PriorityMode.
    pub const PRIORITY_MODE: P = P(0xD207);
    /// VERIFY: libgphoto2 PTP_DPC_FUJI_CurrentState (event list).
    pub const CURRENT_STATE: P = P(0xD212);
    /// VERIFY: libgphoto2 PTP_DPC_FUJI_ShutterSpeed2.
    pub const SHUTTER_SPEED2: P = P(0xD240);
    /// VERIFY
    pub const CAPTURE_REMAINING: P = P(0xD229);
    /// VERIFY
    pub const BATTERY_INFO: P = P(0xD36A);

    /// PriorityMode value that hands exposure control to the host. VERIFY: 2 = "PC/USB".
    pub const PRIORITY_PC: u16 = 2;
}

/// Film simulations. VERIFY: libgphoto2 `fuji_filmsimulation`.
pub const FILM_SIMULATIONS: &[(i64, &str)] = &[
    (1, "Provia"),
    (2, "Velvia"),
    (3, "Astia"),
    (4, "Monochrome"),
    (5, "Sepia"),
    (6, "Pro Neg. Hi"),
    (7, "Pro Neg. Std"),
    (8, "Monochrome + Ye"),
    (9, "Monochrome + R"),
    (10, "Monochrome + G"),
    (11, "Classic Chrome"),
    (12, "Acros"),
    (13, "Acros + Ye"),
    (14, "Acros + R"),
    (15, "Acros + G"),
    (16, "Eterna"),
    (17, "Classic Negative"),
    (18, "Eterna Bleach Bypass"),
    (19, "Nostalgic Neg."),
    (20, "Reala Ace"),
];

/// Fuji white balance adds its own codes. VERIFY: libgphoto2 `fuji_whitebalance`.
pub fn white_balance_display(v: i64) -> String {
    match v {
        0x8001 => "Fluorescent (daylight)".into(),
        0x8002 => "Fluorescent (warm white)".into(),
        0x8003 => "Fluorescent (cool white)".into(),
        0x8006 => "Shade".into(),
        0x8008 => "Underwater".into(),
        0x8010 => "Color temperature".into(),
        0x8020 => "Custom 1".into(),
        0x8021 => "Custom 2".into(),
        0x8022 => "Custom 3".into(),
        _ => format::white_balance_standard(v),
    }
}

pub fn code_for(p: TetherProperty) -> Option<DevicePropCode> {
    match p {
        TetherProperty::PictureStyle => Some(prop::FILM_SIMULATION),
        TetherProperty::ImageQuality => Some(prop::IMAGE_QUALITY),
        _ => GenericPtpHandler::standard_code(p),
    }
}

pub fn property_for(code: DevicePropCode) -> Option<TetherProperty> {
    match code {
        prop::FILM_SIMULATION => Some(TetherProperty::PictureStyle),
        prop::IMAGE_QUALITY => Some(TetherProperty::ImageQuality),
        _ => GenericPtpHandler::standard_property(code),
    }
}

pub fn display(p: TetherProperty, v: &PtpValue) -> String {
    match p {
        TetherProperty::PictureStyle => {
            let n = v.int_value();
            FILM_SIMULATIONS
                .iter()
                .find(|(k, _)| Some(*k) == n)
                .map_or_else(
                    || format!("Film {}", n.unwrap_or(0)),
                    |(_, s)| (*s).to_string(),
                )
        }
        TetherProperty::WhiteBalance => white_balance_display(v.int_value().unwrap_or(0)),
        // VERIFY: Fuji ExposureTime is the standard 1/10 000 s on X-T bodies.
        _ => GenericPtpHandler::format(p, v),
    }
}

/// CurrentState payload: UInt16 count, then (UInt16 code, UInt32 value).
/// VERIFY: layout from libgphoto2's Fuji event handling.
pub fn parse_current_state(data: &[u8]) -> PtpResult<Vec<(DevicePropCode, u32)>> {
    let mut b = ByteBuffer::from(data);
    if b.remaining() < 2 {
        return Ok(Vec::new());
    }
    let n = b.read_u16()?;
    let mut out = Vec::new();
    for _ in 0..n {
        if b.remaining() < 6 {
            break;
        }
        out.push((DevicePropCode(b.read_u16()?), b.read_u32()?));
    }
    Ok(out)
}

/// Fujifilm X / GFX: tether priority gate, standard capture, CurrentState
/// property events, object-handle diff for new files.
pub struct FujifilmHandler {
    pub engine: Arc<PtpEngine>,
    pub info: PtpDeviceInfo,
    capabilities: CameraCapabilities,
    generic: GenericPtpHandler,
    pub differ: ObjectHandleDiffer,
    last_state: Mutex<HashMap<DevicePropCode, u32>>,
}

impl FujifilmHandler {
    pub fn new(engine: Arc<PtpEngine>, info: PtpDeviceInfo) -> Self {
        use CameraCapabilities as C;
        let generic = GenericPtpHandler::new(engine.clone(), info.clone(), None);
        let mut caps = C::empty();
        if info.supports_op(OperationCode::INITIATE_CAPTURE) {
            caps |= C::REMOTE_CAPTURE | C::CARD_CAPTURE | C::AUTOFOCUS;
        }
        if info.supports_op(OperationCode::SET_DEVICE_PROP_VALUE)
            && !info.device_properties_supported.is_empty()
        {
            caps |= C::PROPERTY_CONTROL;
        }
        if info.supports_op(OperationCode::GET_PARTIAL_OBJECT) {
            caps |= C::PARTIAL_TRANSFER;
        }
        if info.supports_op(OperationCode::GET_THUMB) {
            caps |= C::THUMBNAILS;
        }
        Self {
            engine,
            info,
            capabilities: caps,
            generic,
            differ: ObjectHandleDiffer::default(),
            last_state: Mutex::new(HashMap::new()),
        }
    }
}

#[async_trait]
impl VendorHandler for FujifilmHandler {
    fn vendor(&self) -> CameraVendor {
        CameraVendor::Fujifilm
    }

    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities
    }

    fn event_poll_interval(&self) -> Duration {
        Duration::from_millis(500)
    }

    async fn prepare(&self) -> PtpResult<()> {
        if self.info.supports_prop(prop::PRIORITY_MODE) {
            let desc = self
                .engine
                .get_device_prop_desc(prop::PRIORITY_MODE)
                .await?;
            if desc.is_writable && desc.current.int_value() != Some(i64::from(prop::PRIORITY_PC)) {
                self.engine
                    .set_device_prop_value(
                        prop::PRIORITY_MODE,
                        &PtpValue::make(desc.data_type, i64::from(prop::PRIORITY_PC)),
                    )
                    .await?;
            }
        }
        self.differ.seed(&self.engine).await;
        Ok(())
    }

    async fn teardown(&self) {}

    async fn set_capture_destination(&self, destination: CaptureDestination) -> PtpResult<()> {
        if destination != CaptureDestination::Card {
            return Err(PtpError::Unsupported(
                "Fujifilm bodies write to the card; the file is copied over afterwards.".into(),
            ));
        }
        Ok(())
    }

    async fn capture(&self, _autofocus: bool) -> PtpResult<()> {
        if !self.info.supports_op(OperationCode::INITIATE_CAPTURE) {
            return Err(PtpError::VendorGate(
                "Set the camera to USB TETHER SHOOTING AUTO (or PC connection for Wi-Fi) and reconnect.".into(),
            ));
        }
        run(
            &self.engine,
            OperationCode::INITIATE_CAPTURE,
            &[0, 0],
            Some(30.0),
            false,
        )
        .await
        .map(|_| ())
    }

    async fn poll_events(&self) -> PtpResult<Vec<CameraEvent>> {
        let mut out = Vec::new();
        if self.info.supports_prop(prop::CURRENT_STATE) {
            let data = self
                .engine
                .get_raw_prop_value(prop::CURRENT_STATE.0)
                .await?;
            let mut last = lock(&self.last_state);
            for (code, value) in parse_current_state(&data)? {
                if last.get(&code) != Some(&value) {
                    last.insert(code, value);
                    if let Some(p) = property_for(code) {
                        out.push(CameraEvent::PropertyChanged(Some(p)));
                    }
                }
            }
        }
        out.extend(self.differ.poll(&self.engine).await?);
        Ok(out)
    }

    async fn translate(&self, e: &PtpEvent) -> Option<CameraEvent> {
        if e.code == EventCode::OBJECT_ADDED {
            if let Some(&h) = e.parameters.first() {
                // Keep the differ from re-announcing a pushed handle.
                self.differ.mark_known(h);
            }
        }
        self.generic.translate(e).await
    }

    async fn read_properties(
        &self,
        properties: &[TetherProperty],
    ) -> PtpResult<Vec<PropertyDescriptor>> {
        let mut out =
            vendor_props::read_standard(&self.engine, &self.info, properties, code_for, &display)
                .await?;
        if properties.contains(&TetherProperty::CaptureDestination) {
            out.push(vendor_props::destination_descriptor(
                CaptureDestination::Card,
                &[CaptureDestination::Card],
                false,
            ));
        }
        Ok(out)
    }

    async fn write_property(&self, property: TetherProperty, raw: PtpValue) -> PtpResult<()> {
        let Some(c) = code_for(property).filter(|c| self.info.supports_prop(*c)) else {
            return Err(cannot_set(property));
        };
        self.engine.set_device_prop_value(c, &raw).await
    }

    async fn fetch_object(
        &self,
        object: &NewObject,
        progress: Option<ProgressFn>,
    ) -> PtpResult<(PtpObjectInfo, Vec<u8>)> {
        self.generic.fetch_object(object, progress).await
    }
}
