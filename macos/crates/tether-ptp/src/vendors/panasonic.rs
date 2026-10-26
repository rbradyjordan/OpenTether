//! Panasonic Lumix (wired only): vendor property get/set, vendor capture,
//! live view, object-handle diff for new files. Ported from
//! `PanasonicHandler.swift`.
//!
//! Constants follow libgphoto2 `PTP_OC_PANASONIC_*`, `PTP_DPC_PANASONIC_*`.
//! Property codes are 32-bit. All VERIFY.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tether_types::{
    jpeg_payload, CameraCapabilities, CameraVendor, CaptureDestination, LiveViewFrame,
    LiveViewQuality,
};

use super::{cannot_set, live_frame, needs_numeric, no_live_view, run, run_out};
use crate::device::property::format;
use crate::device::{
    vendor_props, CameraEvent, GenericPtpHandler, NewObject, ObjectHandleDiffer,
    PropertyDescriptor, PropertyForm, TetherProperty, VendorHandler,
};
use crate::ptp::transport::lock;
use crate::ptp::{
    ByteBuffer, EventCode, OperationCode, ProgressFn, PtpDeviceInfo, PtpEngine, PtpError, PtpEvent,
    PtpObjectInfo, PtpRequest, PtpResult, PtpValue,
};

/// Panasonic operation codes.
pub mod op {
    use crate::ptp::OperationCode as O;
    /// VERIFY: libgphoto2 PTP_OC_PANASONIC_GetProperty.
    pub const GET_PROPERTY: O = O(0x9402);
    /// VERIFY: libgphoto2 PTP_OC_PANASONIC_SetProperty.
    pub const SET_PROPERTY: O = O(0x9403);
    /// VERIFY: libgphoto2 PTP_OC_PANASONIC_InitiateCapture.
    pub const INITIATE_CAPTURE: O = O(0x9404);
    /// VERIFY: libgphoto2 PTP_OC_PANASONIC_ListProperty.
    pub const LIST_PROPERTY: O = O(0x9108);
    /// VERIFY: libgphoto2 PTP_OC_PANASONIC_Liveview.
    pub const LIVEVIEW: O = O(0x9412);
    /// VERIFY: libgphoto2 PTP_OC_PANASONIC_LiveviewImage.
    pub const LIVEVIEW_IMAGE: O = O(0x9706);
    /// VERIFY
    pub const GET_CAPTURE_TARGET: O = O(0x9405);
}

/// Panasonic 32-bit property codes.
pub mod prop {
    pub const WHITE_BALANCE: u32 = 0x0200_0010; // VERIFY
    pub const ISO: u32 = 0x0200_0020; // VERIFY
    pub const SHUTTER_SPEED: u32 = 0x0200_0030; // VERIFY
    pub const APERTURE: u32 = 0x0200_0040; // VERIFY
    pub const EXPOSURE: u32 = 0x0200_0050; // VERIFY
    pub const AF_MODE: u32 = 0x0200_0080; // VERIFY
    /// VERIFY: no libgphoto2 reference; placeholder, only read when GetProperty answers.
    pub const BATTERY: u32 = 0x1600_0010;
}

/// Panasonic event codes.
pub mod event {
    use crate::ptp::EventCode as E;
    /// VERIFY: libgphoto2 PTP_EC_PANASONIC_ObjectAdded.
    pub const OBJECT_ADDED: E = E(0xC102);
    /// VERIFY
    pub const OBJECT_ADDED_SDRAM: E = E(0xC103);
}

/// VERIFY: libgphoto2 ptp_panasonic_capture.
pub const CAPTURE_PARAM: u32 = 0x0300_0011;
pub const LIVEVIEW_START: u32 = 0x0D00_0010; // VERIFY
pub const LIVEVIEW_STOP: u32 = 0x0D00_0011; // VERIFY

/// Shutter: 0xFFFFFFFF = bulb; high bit set → seconds × 1000; else 1/(v/1000).
/// VERIFY: libgphoto2 `_get_Panasonic_Shutter`.
pub fn shutter_display(v: u32) -> String {
    if v == 0xFFFF_FFFF {
        return "Bulb".into();
    }
    if v & 0x8000_0000 != 0 {
        return format::shutter_seconds(f64::from(v & 0x7FFF_FFFF) / 1000.0);
    }
    if v == 0 {
        return "?".into();
    }
    format!("1/{}", v / 1000)
}

/// Aperture is f-number × 10. VERIFY: libgphoto2 `_get_Panasonic_FNumber`.
pub fn aperture_display(v: u32) -> String {
    format::aperture(i64::from(v) * 10)
}

/// Exposure compensation in 1/3 EV steps (signed). VERIFY: libgphoto2 `_get_Panasonic_Exposure`.
pub fn exposure_display(v: u32) -> String {
    let thirds = v as i32;
    format::exposure_compensation(i64::from(thirds) * 1000 / 3)
}

/// VERIFY: libgphoto2 `_get_Panasonic_Whitebalance`.
pub const WHITE_BALANCES: &[(u32, &str)] = &[
    (2, "Auto"),
    (4, "Daylight"),
    (0x8008, "Cloudy"),
    (0x8009, "Shade"),
    (6, "Tungsten"),
    (7, "Flash"),
    (0x8020, "White set 1"),
    (0x8021, "White set 2"),
    (0x8022, "White set 3"),
    (0x8023, "White set 4"),
    (0x8010, "Color temperature 1"),
    (0x8011, "Color temperature 2"),
    (0x8012, "Color temperature 3"),
    (0x8013, "Color temperature 4"),
    (0x8002, "Auto (cool)"),
    (0x8003, "Auto (warm)"),
];

pub fn display(p: TetherProperty, v: u32) -> String {
    match p {
        TetherProperty::ShutterSpeed => shutter_display(v),
        TetherProperty::Aperture => aperture_display(v),
        TetherProperty::Iso => format::iso(i64::from(v)),
        TetherProperty::ExposureCompensation => exposure_display(v),
        TetherProperty::WhiteBalance => WHITE_BALANCES
            .iter()
            .find(|(k, _)| *k == v)
            .map_or_else(|| format!("WB {v}"), |(_, s)| (*s).to_string()),
        TetherProperty::BatteryLevel => format::battery(i64::from(v)),
        _ => v.to_string(),
    }
}

pub fn code_for(p: TetherProperty) -> Option<u32> {
    use TetherProperty as P;
    Some(match p {
        P::Aperture => prop::APERTURE,
        P::ShutterSpeed => prop::SHUTTER_SPEED,
        P::Iso => prop::ISO,
        P::ExposureCompensation => prop::EXPOSURE,
        P::WhiteBalance => prop::WHITE_BALANCE,
        P::FocusMode => prop::AF_MODE,
        P::BatteryLevel => prop::BATTERY,
        _ => return None,
    })
}

pub fn property_for(code: u32) -> Option<TetherProperty> {
    use TetherProperty as P;
    Some(match code {
        prop::APERTURE => P::Aperture,
        prop::SHUTTER_SPEED => P::ShutterSpeed,
        prop::ISO => P::Iso,
        prop::EXPOSURE => P::ExposureCompensation,
        prop::WHITE_BALANCE => P::WhiteBalance,
        prop::AF_MODE => P::FocusMode,
        prop::BATTERY => P::BatteryLevel,
        _ => return None,
    })
}

/// A Panasonic GetProperty answer: `UInt32 code, UInt32 size, value`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanasonicPropertyValue {
    pub code: u32,
    pub value: u32,
    pub raw: Vec<u8>,
}

impl PanasonicPropertyValue {
    pub fn new(code: u32, value: u32) -> Self {
        Self {
            code,
            value,
            raw: value.to_le_bytes().to_vec(),
        }
    }

    pub fn parse(data: &[u8]) -> PtpResult<Self> {
        let mut b = ByteBuffer::from(data);
        let code = b.read_u32()?;
        let size = b.read_u32()? as usize;
        if size > b.remaining() {
            return Err(PtpError::Malformed(format!(
                "Panasonic property size {size} exceeds payload"
            )));
        }
        let raw = b.read_bytes(size)?;
        let mut v = ByteBuffer::from(raw.clone());
        let value = match size {
            1 => u32::from(v.read_u8()?),
            2 => u32::from(v.read_u16()?),
            4 => v.read_u32()?,
            _ => v.read_u32().unwrap_or(0),
        };
        Ok(Self { code, value, raw })
    }

    /// SetProperty payload: same layout as the GetProperty answer.
    pub fn encoded(&self) -> Vec<u8> {
        let mut b = ByteBuffer::new();
        b.write_u32(self.code);
        b.write_u32(self.raw.len() as u32);
        b.write_bytes(&self.raw);
        b.into_bytes()
    }
}

struct LiveState {
    on: bool,
    frame_sequence: u64,
}

/// Panasonic Lumix (wired only): vendor property get/set, vendor capture,
/// live view, object-handle diff for new files.
pub struct PanasonicHandler {
    pub engine: Arc<PtpEngine>,
    pub info: PtpDeviceInfo,
    capabilities: CameraCapabilities,
    generic: GenericPtpHandler,
    pub differ: ObjectHandleDiffer,
    live: Mutex<LiveState>,
}

impl PanasonicHandler {
    pub fn new(engine: Arc<PtpEngine>, info: PtpDeviceInfo) -> Self {
        use CameraCapabilities as C;
        let generic = GenericPtpHandler::new(engine.clone(), info.clone(), None);
        let mut caps = C::empty();
        if info.supports_op(op::INITIATE_CAPTURE)
            || info.supports_op(OperationCode::INITIATE_CAPTURE)
        {
            caps |= C::REMOTE_CAPTURE | C::CARD_CAPTURE;
        }
        if info.supports_op(op::INITIATE_CAPTURE) {
            caps |= C::AUTOFOCUS;
        }
        if info.supports_op(op::LIVEVIEW) && info.supports_op(op::LIVEVIEW_IMAGE) {
            caps |= C::LIVE_VIEW;
        }
        if info.supports_op(op::GET_PROPERTY) && info.supports_op(op::SET_PROPERTY) {
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
            live: Mutex::new(LiveState {
                on: false,
                frame_sequence: 0,
            }),
        }
    }

    pub async fn get_property(&self, code: u32) -> PtpResult<PanasonicPropertyValue> {
        let r = run(&self.engine, op::GET_PROPERTY, &[code], None, false).await?;
        PanasonicPropertyValue::parse(&r.data_in)
    }
}

#[async_trait]
impl VendorHandler for PanasonicHandler {
    fn vendor(&self) -> CameraVendor {
        CameraVendor::Panasonic
    }

    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities
    }

    fn event_poll_interval(&self) -> Duration {
        Duration::from_millis(500)
    }

    async fn prepare(&self) -> PtpResult<()> {
        self.differ.seed(&self.engine).await;
        Ok(())
    }

    async fn teardown(&self) {
        self.stop_live_view().await;
    }

    async fn set_capture_destination(&self, destination: CaptureDestination) -> PtpResult<()> {
        if destination != CaptureDestination::Card {
            return Err(PtpError::Unsupported(
                "Lumix bodies write to the card; the file is copied over afterwards.".into(),
            ));
        }
        Ok(())
    }

    async fn capture(&self, _autofocus: bool) -> PtpResult<()> {
        if self.info.supports_op(op::INITIATE_CAPTURE) {
            run(
                &self.engine,
                op::INITIATE_CAPTURE,
                &[CAPTURE_PARAM],
                Some(30.0),
                false,
            )
            .await
            .map(|_| ())
        } else if self.info.supports_op(OperationCode::INITIATE_CAPTURE) {
            self.engine.initiate_capture(0, None).await
        } else {
            Err(PtpError::Unsupported(
                "This camera does not support remote capture over PTP.".into(),
            ))
        }
    }

    async fn poll_events(&self) -> PtpResult<Vec<CameraEvent>> {
        self.differ.poll(&self.engine).await
    }

    async fn translate(&self, e: &PtpEvent) -> Option<CameraEvent> {
        match e.code {
            event::OBJECT_ADDED | event::OBJECT_ADDED_SDRAM => {
                let h = e.parameters.first().copied().filter(|&h| h != 0)?;
                self.differ.mark_known(h);
                Some(CameraEvent::ObjectAdded(NewObject {
                    in_sdram: e.code == event::OBJECT_ADDED_SDRAM,
                    ..NewObject::new(h)
                }))
            }
            _ => {
                if e.code == EventCode::OBJECT_ADDED {
                    if let Some(&h) = e.parameters.first() {
                        self.differ.mark_known(h);
                    }
                }
                self.generic.translate(e).await
            }
        }
    }

    async fn read_properties(
        &self,
        properties: &[TetherProperty],
    ) -> PtpResult<Vec<PropertyDescriptor>> {
        let card_only = || {
            vendor_props::destination_descriptor(
                CaptureDestination::Card,
                &[CaptureDestination::Card],
                false,
            )
        };
        if !self.info.supports_op(op::GET_PROPERTY) {
            let mut out = self.generic.read_properties(properties).await?;
            if properties.contains(&TetherProperty::CaptureDestination) {
                out.push(card_only());
            }
            return Ok(out);
        }
        let mut out = Vec::new();
        for &p in properties {
            if p == TetherProperty::CaptureDestination {
                out.push(card_only());
                continue;
            }
            let Some(code) = code_for(p) else { continue };
            let r = self
                .engine
                .execute(PtpRequest::new(op::GET_PROPERTY, [code]))
                .await?;
            if !r.is_ok() {
                continue;
            }
            let Ok(v) = PanasonicPropertyValue::parse(&r.data_in) else {
                continue;
            };
            let writable = self
                .capabilities
                .contains(CameraCapabilities::PROPERTY_CONTROL)
                && p != TetherProperty::BatteryLevel;
            out.push(PropertyDescriptor::new(
                p,
                PtpValue::UInt32(v.value),
                display(p, v.value),
                writable,
                PropertyForm::Other,
            ));
        }
        Ok(out)
    }

    async fn write_property(&self, property: TetherProperty, raw: PtpValue) -> PtpResult<()> {
        let Some(code) = code_for(property).filter(|_| {
            self.info.supports_op(op::SET_PROPERTY) && property != TetherProperty::BatteryLevel
        }) else {
            return Err(cannot_set(property));
        };
        let Some(v) = raw.uint_value() else {
            return Err(needs_numeric(property));
        };
        let payload = PanasonicPropertyValue::new(code, v as u32);
        run_out(&self.engine, op::SET_PROPERTY, &[code], payload.encoded())
            .await
            .map(|_| ())
    }

    async fn fetch_object(
        &self,
        object: &NewObject,
        progress: Option<ProgressFn>,
    ) -> PtpResult<(PtpObjectInfo, Vec<u8>)> {
        self.generic.fetch_object(object, progress).await
    }

    async fn start_live_view(&self, _quality: LiveViewQuality) -> PtpResult<()> {
        if !self.capabilities.contains(CameraCapabilities::LIVE_VIEW) {
            return Err(no_live_view());
        }
        run(&self.engine, op::LIVEVIEW, &[LIVEVIEW_START], None, false).await?;
        lock(&self.live).on = true;
        Ok(())
    }

    async fn stop_live_view(&self) {
        {
            let mut l = lock(&self.live);
            if !l.on {
                return;
            }
            l.on = false;
        }
        let _ = self
            .engine
            .execute(PtpRequest::new(op::LIVEVIEW, [LIVEVIEW_STOP]))
            .await;
    }

    async fn next_live_view_frame(&self) -> PtpResult<Option<LiveViewFrame>> {
        if !lock(&self.live).on {
            return Ok(None);
        }
        let req = PtpRequest::new(op::LIVEVIEW_IMAGE, [])
            .expecting_large_data(true)
            .with_timeout(Duration::from_secs(5));
        let r = self.engine.execute(req).await?;
        if !r.is_ok() {
            return Ok(None);
        }
        let Some(jpeg) = jpeg_payload(&r.data_in) else {
            return Ok(None);
        };
        let mut l = lock(&self.live);
        l.frame_sequence += 1;
        Ok(Some(live_frame(jpeg.to_vec(), l.frame_sequence)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn value_tables() {
        assert_eq!(shutter_display(125_000), "1/125");
        assert_eq!(shutter_display(0x8000_0000 | 4000), "4\"");
        assert_eq!(shutter_display(0), "?");
        assert_eq!(aperture_display(28), "ƒ/2.8");
        assert_eq!(exposure_display((-2i32) as u32), "-0.7");
        assert_eq!(exposure_display(3), "+1");
        assert_eq!(display(TetherProperty::WhiteBalance, 0x8009), "Shade");
        assert_eq!(display(TetherProperty::WhiteBalance, 99), "WB 99");
        for p in TetherProperty::ALL {
            if let Some(c) = code_for(p) {
                assert_eq!(property_for(c), Some(p));
            }
        }
    }

    #[test]
    fn property_value_sizes() {
        let v = PanasonicPropertyValue::parse(&[1, 0, 0, 0, 1, 0, 0, 0, 7]).unwrap();
        assert_eq!(v.value, 7);
        assert!(PanasonicPropertyValue::parse(&[1, 0, 0, 0, 9, 0, 0, 0, 7]).is_err());
        let round = PanasonicPropertyValue::new(prop::ISO, 800);
        assert_eq!(
            PanasonicPropertyValue::parse(&round.encoded()).unwrap(),
            round
        );
    }
}
