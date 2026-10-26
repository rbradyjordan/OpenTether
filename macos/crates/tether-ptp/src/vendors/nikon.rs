//! Nikon: DeviceReady gate (Z bodies also need the application-mode switch),
//! polled GetEvent, SDRAM capture on 0xFFFF0001, live view with the
//! prohibit-condition check. Ported from `NikonHandler.swift`.
//!
//! Constants are named after libgphoto2 `ptp.h` (`PTP_OC_NIKON_*`,
//! `PTP_DPC_NIKON_*`, `PTP_EC_NIKON_*`). VERIFY marks the unconfirmed ones.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tether_types::{
    jpeg_payload, CameraCapabilities, CameraVendor, CaptureDestination, LiveViewFrame,
    LiveViewQuality,
};

use super::{cannot_set, live_frame, no_live_view, run};
use crate::device::property::format;
use crate::device::{
    vendor_props, CameraEvent, GenericPtpHandler, NewObject, PropertyDescriptor, TetherProperty,
    VendorHandler,
};
use crate::ptp::transport::lock;
use crate::ptp::{
    ByteBuffer, DataType, DevicePropCode, EventCode, OperationCode, ProgressFn, PtpDeviceInfo,
    PtpEngine, PtpError, PtpEvent, PtpObjectInfo, PtpRequest, PtpResult, PtpValue, ResponseCode,
};

/// Nikon operation codes.
pub mod op {
    use crate::ptp::OperationCode as O;
    pub const GET_PROFILE_ALL_DATA: O = O(0x9006);
    /// VERIFY: Z-series gate; candidate from libgphoto2 PTP_OC_NIKON_ChangeApplicationMode.
    pub const CHANGE_APPLICATION_MODE: O = O(0x9038);
    pub const INITIATE_CAPTURE_REC_IN_SDRAM: O = O(0x90C0);
    pub const AF_DRIVE: O = O(0x90C1);
    /// VERIFY: libgphoto2 PTP_OC_NIKON_ChangeCameraMode; second gate candidate.
    pub const CHANGE_CAMERA_MODE: O = O(0x90C2);
    pub const DELETE_IMAGES_IN_SDRAM: O = O(0x90C3);
    pub const GET_LARGE_THUMB: O = O(0x90C4);
    pub const GET_EVENT: O = O(0x90C7);
    pub const DEVICE_READY: O = O(0x90C8);
    pub const SET_PRE_WB_DATA: O = O(0x90C9);
    pub const GET_VENDOR_PROP_CODES: O = O(0x90CA);
    pub const AF_CAPTURE_SDRAM: O = O(0x90CB);
    pub const GET_PICT_CTRL_DATA: O = O(0x90CC);
    pub const SET_PICT_CTRL_DATA: O = O(0x90CD);
    pub const GET_DEVICE_PTPIP_INFO: O = O(0x90E0);
    pub const GET_PREVIEW_IMG: O = O(0x9200);
    pub const START_LIVE_VIEW: O = O(0x9201);
    pub const END_LIVE_VIEW: O = O(0x9202);
    pub const GET_LIVE_VIEW_IMG: O = O(0x9203);
    pub const MF_DRIVE: O = O(0x9204);
    pub const CHANGE_AF_AREA: O = O(0x9205);
    pub const AF_DRIVE_CANCEL: O = O(0x9206);
    pub const INITIATE_CAPTURE_REC_IN_MEDIA: O = O(0x9207);
    pub const GET_VENDOR_STORAGE_IDS: O = O(0x9209);
    pub const START_MOVIE_REC_IN_CARD: O = O(0x920A);
    pub const END_MOVIE_REC: O = O(0x920B);
    pub const TERMINATE_CAPTURE: O = O(0x920C);
    /// VERIFY
    pub const GET_PARTIAL_OBJECT_HI_SPEED: O = O(0x9400);
}

/// Nikon device property codes.
pub mod prop {
    use crate::ptp::DevicePropCode as P;
    pub const SHUTTER_SPEED: P = P(0xD100);
    pub const EXTERNAL_FLASH_ATTACHED: P = P(0xD120);
    pub const LIVE_VIEW_STATUS: P = P(0xD1A2);
    pub const LIVE_VIEW_IMAGE_ZOOM_RATIO: P = P(0xD1A3);
    pub const LIVE_VIEW_PROHIBIT_CONDITION: P = P(0xD1A4);
    /// VERIFY
    pub const LIVE_VIEW_IMAGE_SIZE: P = P(0xD1AC);
    /// VERIFY
    pub const EXPOSURE_INDEX_EX: P = P(0xD1C5);
    pub const BULB_SHUTTER: u32 = 0xFFFF_FFFF;
}

/// Nikon event codes.
pub mod event {
    use crate::ptp::EventCode as E;
    pub const OBJECT_ADDED_IN_SDRAM: E = E(0xC101);
    pub const CAPTURE_COMPLETE_REC_IN_SDRAM: E = E(0xC102);
    pub const ADVANCED_TRANSFER: E = E(0xC103);
    pub const PREVIEW_IMAGE_ADDED: E = E(0xC104);
    pub const MOVIE_RECORD_INTERRUPTED: E = E(0xC105);
    /// VERIFY
    pub const FIRST_CAPTURE_COMPLETE: E = E(0xC107);
    /// VERIFY
    pub const MIRROR_UP_AFTER_SHOOT: E = E(0xC108);
}

/// Handle Nikon assigns to the image waiting in SDRAM.
pub const SDRAM_HANDLE: u32 = 0xFFFF_0001;

/// InitiateCaptureRecInMedia parameters. VERIFY: libgphoto2 passes
/// (af ? 0 : 0xFFFFFFFF, sdram+card ? 1 : 0).
pub const CAPTURE_NO_AF: u32 = 0xFFFF_FFFF;

/// LiveViewProhibitCondition bits → why live view is refused.
/// VERIFY: libgphoto2 `_get_Nikon_LiveViewProhibitCondition`.
pub const PROHIBIT_REASONS: &[(u32, &str)] = &[
    (0, "Recording destination is the card"),
    (2, "Sequence error"),
    (4, "Shutter button fully pressed"),
    (5, "Aperture ring is not set to minimum"),
    (6, "Bulb exposure warning"),
    (7, "Mirror is up"),
    (8, "Battery exhausted"),
    (9, "TTL error"),
    (11, "Mode dial is not on a shooting mode"),
    (12, "Minimum aperture warning"),
    (14, "Capture in progress"),
    (15, "Sensor cleaning"),
    (16, "Camera temperature too high"),
    (17, "No lens attached"),
];

pub fn prohibit_description(bits: u32) -> String {
    let reasons: Vec<String> = (0..32u32)
        .filter(|bit| bits & (1 << bit) != 0)
        .map(|bit| {
            PROHIBIT_REASONS
                .iter()
                .find(|(b, _)| *b == bit)
                .map_or_else(|| format!("Condition bit {bit}"), |(_, r)| (*r).to_string())
        })
        .collect();
    if reasons.is_empty() {
        "Live view is blocked by the camera.".into()
    } else {
        format!("Live view is blocked: {}.", reasons.join("; "))
    }
}

/// Nikon ShutterSpeed 0xD100: UInt32 numerator << 16 | denominator; 0xFFFFFFFF = bulb.
pub fn shutter_display(v: u32) -> String {
    if v == prop::BULB_SHUTTER {
        return "Bulb".into();
    }
    format::shutter_fraction(i64::from(v >> 16), i64::from(v & 0xFFFF))
}

/// Nikon WhiteBalance extends the standard codes with 0x8010+.
/// VERIFY: libgphoto2 `nikon_whitebalance`.
pub fn white_balance_display(v: i64) -> String {
    match v {
        0x8010 => "Cloudy".into(),
        0x8011 => "Shade".into(),
        0x8012 => "Color temperature".into(),
        0x8013 => "Preset".into(),
        0x8014 => "Natural light auto".into(),
        _ => format::white_balance_standard(v),
    }
}

struct NikonState {
    destination: CaptureDestination,
    live_view_on: bool,
    frame_sequence: u64,
}

/// Nikon: DeviceReady gate (Z bodies also need the application-mode switch),
/// polled GetEvent, SDRAM capture on 0xFFFF0001, live view with the
/// prohibit-condition check.
pub struct NikonHandler {
    pub engine: Arc<PtpEngine>,
    pub info: PtpDeviceInfo,
    capabilities: CameraCapabilities,
    generic: GenericPtpHandler,
    sdram_capable: bool,
    state: Mutex<NikonState>,
    /// DeviceReady retries before giving up (each waits 100 ms).
    ready_attempts: AtomicU32,
}

impl NikonHandler {
    pub fn new(engine: Arc<PtpEngine>, info: PtpDeviceInfo) -> Self {
        use CameraCapabilities as C;
        let generic = GenericPtpHandler::new(engine.clone(), info.clone(), None);
        let sdram = info.supports_op(op::INITIATE_CAPTURE_REC_IN_SDRAM)
            || info.supports_op(op::AF_CAPTURE_SDRAM);
        let card = info.supports_op(OperationCode::INITIATE_CAPTURE)
            || info.supports_op(op::INITIATE_CAPTURE_REC_IN_MEDIA);
        let mut caps = C::empty();
        if sdram || card {
            caps |= C::REMOTE_CAPTURE;
        }
        if sdram {
            caps |= C::SDRAM_CAPTURE;
        }
        if card {
            caps |= C::CARD_CAPTURE;
        }
        if info.supports_op(op::START_LIVE_VIEW) && info.supports_op(op::GET_LIVE_VIEW_IMG) {
            caps |= C::LIVE_VIEW;
        }
        if info.supports_op(OperationCode::SET_DEVICE_PROP_VALUE)
            && !info.device_properties_supported.is_empty()
        {
            caps |= C::PROPERTY_CONTROL;
        }
        if info.supports_op(OperationCode::GET_PARTIAL_OBJECT) {
            caps |= C::PARTIAL_TRANSFER;
        }
        if info.supports_op(op::AF_CAPTURE_SDRAM) || info.supports_op(op::AF_DRIVE) {
            caps |= C::AUTOFOCUS;
        }
        if info.supports_op(OperationCode::GET_THUMB) || info.supports_op(op::GET_LARGE_THUMB) {
            caps |= C::THUMBNAILS;
        }
        if info.supports_prop(prop::SHUTTER_SPEED) {
            caps |= C::BULB_CAPTURE;
        }
        let destination = if sdram {
            CaptureDestination::Host
        } else {
            CaptureDestination::Card
        };
        Self {
            engine,
            info,
            capabilities: caps,
            generic,
            sdram_capable: sdram,
            state: Mutex::new(NikonState {
                destination,
                live_view_on: false,
                frame_sequence: 0,
            }),
            ready_attempts: AtomicU32::new(50),
        }
    }

    pub fn ready_attempts(&self) -> u32 {
        self.ready_attempts.load(Ordering::Relaxed)
    }

    pub fn set_ready_attempts(&self, n: u32) {
        self.ready_attempts.store(n, Ordering::Relaxed);
    }

    pub fn destination(&self) -> CaptureDestination {
        lock(&self.state).destination
    }

    /// The application-mode opcode this body advertises, if any.
    pub fn application_mode_op(&self) -> Option<OperationCode> {
        if self.info.supports_op(op::CHANGE_APPLICATION_MODE) {
            Some(op::CHANGE_APPLICATION_MODE)
        } else if self.info.supports_op(op::CHANGE_CAMERA_MODE) {
            Some(op::CHANGE_CAMERA_MODE)
        } else {
            None
        }
    }

    /// DeviceReady until OK. The engine already retries DeviceBusy with
    /// backoff; this loop covers bodies that answer other transient codes.
    pub async fn wait_until_ready(&self) -> PtpResult<()> {
        if !self.info.supports_op(op::DEVICE_READY) {
            return Ok(());
        }
        let mut attempt = 0u32;
        loop {
            let r = self
                .engine
                .execute(PtpRequest::new(op::DEVICE_READY, []))
                .await?;
            if r.is_ok() {
                return Ok(());
            }
            attempt += 1;
            if r.code != ResponseCode::DEVICE_BUSY || attempt >= self.ready_attempts() {
                return Err(PtpError::Response {
                    op: op::DEVICE_READY,
                    code: r.code,
                    parameters: r.parameters,
                });
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    /// GetEvent payload: UInt16 count, then (UInt16 code, UInt32 param) pairs.
    pub fn parse_events(data: &[u8]) -> PtpResult<Vec<PtpEvent>> {
        let mut b = ByteBuffer::from(data);
        if b.remaining() < 2 {
            return Ok(Vec::new());
        }
        let count = b.read_u16()?;
        let mut out = Vec::new();
        for _ in 0..count {
            if b.remaining() < 6 {
                break;
            }
            let code = EventCode(b.read_u16()?);
            let param = b.read_u32()?;
            out.push(PtpEvent::new(code, [param]));
        }
        Ok(out)
    }

    pub fn code_for(&self, p: TetherProperty) -> Option<DevicePropCode> {
        if p == TetherProperty::ShutterSpeed && self.info.supports_prop(prop::SHUTTER_SPEED) {
            return Some(prop::SHUTTER_SPEED);
        }
        if p == TetherProperty::LiveViewEnabled {
            return Some(prop::LIVE_VIEW_STATUS);
        }
        GenericPtpHandler::standard_code(p)
    }

    pub fn format(p: TetherProperty, v: &PtpValue, nikon_shutter: bool) -> String {
        match p {
            TetherProperty::ShutterSpeed if nikon_shutter => {
                shutter_display(v.uint_value().unwrap_or(0) as u32)
            }
            TetherProperty::WhiteBalance => white_balance_display(v.int_value().unwrap_or(0)),
            _ => GenericPtpHandler::format(p, v),
        }
    }
}

#[async_trait]
impl VendorHandler for NikonHandler {
    fn vendor(&self) -> CameraVendor {
        CameraVendor::Nikon
    }

    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities
    }

    fn event_poll_interval(&self) -> Duration {
        Duration::from_millis(250)
    }

    // MARK: Gate

    async fn prepare(&self) -> PtpResult<()> {
        if let Some(o) = self.application_mode_op() {
            run(&self.engine, o, &[1], None, false).await?;
        }
        self.wait_until_ready().await
    }

    async fn teardown(&self) {
        self.stop_live_view().await;
        if let Some(o) = self.application_mode_op() {
            let _ = self.engine.execute(PtpRequest::new(o, [0])).await;
        }
    }

    // MARK: Capture

    async fn set_capture_destination(&self, d: CaptureDestination) -> PtpResult<()> {
        match d {
            CaptureDestination::Card
                if !self.capabilities.contains(CameraCapabilities::CARD_CAPTURE) =>
            {
                return Err(PtpError::Unsupported(
                    "This Nikon can only capture to memory over PTP.".into(),
                ))
            }
            CaptureDestination::Host if !self.sdram_capable => {
                return Err(PtpError::Unsupported(
                    "This Nikon cannot capture to memory; use the card.".into(),
                ))
            }
            CaptureDestination::Both
                if !self.sdram_capable
                    || !self.info.supports_op(op::INITIATE_CAPTURE_REC_IN_MEDIA) =>
            {
                return Err(PtpError::Unsupported(
                    "This Nikon cannot record to card and memory at once.".into(),
                ))
            }
            _ => {}
        }
        lock(&self.state).destination = d;
        Ok(())
    }

    async fn capture(&self, autofocus: bool) -> PtpResult<()> {
        let destination = self.destination();
        if destination == CaptureDestination::Host && self.sdram_capable {
            if autofocus && self.info.supports_op(op::AF_CAPTURE_SDRAM) {
                run(&self.engine, op::AF_CAPTURE_SDRAM, &[], Some(30.0), false).await?;
            } else if self.info.supports_op(op::INITIATE_CAPTURE_REC_IN_SDRAM) {
                run(
                    &self.engine,
                    op::INITIATE_CAPTURE_REC_IN_SDRAM,
                    &[0xFFFF_FFFF],
                    Some(30.0),
                    false,
                )
                .await?;
            } else {
                run(&self.engine, op::AF_CAPTURE_SDRAM, &[], Some(30.0), false).await?;
            }
        } else if self.info.supports_op(op::INITIATE_CAPTURE_REC_IN_MEDIA) {
            let af = if autofocus { 0 } else { CAPTURE_NO_AF };
            let both = u32::from(destination == CaptureDestination::Both);
            run(
                &self.engine,
                op::INITIATE_CAPTURE_REC_IN_MEDIA,
                &[af, both],
                Some(30.0),
                false,
            )
            .await?;
        } else if self.info.supports_op(OperationCode::INITIATE_CAPTURE) {
            self.engine.initiate_capture(0, None).await?;
        } else {
            return Err(PtpError::Unsupported(
                "This Nikon does not support remote capture over PTP.".into(),
            ));
        }
        self.wait_until_ready().await
    }

    // MARK: Events

    async fn poll_events(&self) -> PtpResult<Vec<CameraEvent>> {
        if !self.info.supports_op(op::GET_EVENT) {
            return Ok(Vec::new());
        }
        let r = run(&self.engine, op::GET_EVENT, &[], None, false).await?;
        let mut out = Vec::new();
        for ev in Self::parse_events(&r.data_in)? {
            if let Some(t) = self.translate(&ev).await {
                out.push(t);
            }
        }
        Ok(out)
    }

    async fn translate(&self, e: &PtpEvent) -> Option<CameraEvent> {
        match e.code {
            event::OBJECT_ADDED_IN_SDRAM => {
                let h = e.parameters.first().copied().unwrap_or(SDRAM_HANDLE);
                Some(CameraEvent::ObjectAdded(NewObject {
                    in_sdram: true,
                    ..NewObject::new(if h == 0 { SDRAM_HANDLE } else { h })
                }))
            }
            event::CAPTURE_COMPLETE_REC_IN_SDRAM | event::FIRST_CAPTURE_COMPLETE => {
                Some(CameraEvent::CaptureComplete)
            }
            event::PREVIEW_IMAGE_ADDED | event::ADVANCED_TRANSFER => None,
            event::MOVIE_RECORD_INTERRUPTED => Some(CameraEvent::Warning(
                "Movie recording was interrupted.".into(),
            )),
            EventCode::DEVICE_PROP_CHANGED => {
                if let Some(&p) = e.parameters.first() {
                    if DevicePropCode(p as u16) == prop::SHUTTER_SPEED {
                        return Some(CameraEvent::PropertyChanged(Some(
                            TetherProperty::ShutterSpeed,
                        )));
                    }
                }
                self.generic.translate(e).await
            }
            _ => self.generic.translate(e).await,
        }
    }

    // MARK: Properties

    async fn read_properties(
        &self,
        properties: &[TetherProperty],
    ) -> PtpResult<Vec<PropertyDescriptor>> {
        let nikon_shutter = self.info.supports_prop(prop::SHUTTER_SPEED);
        let fmt = move |p: TetherProperty, v: &PtpValue| Self::format(p, v, nikon_shutter);
        let mut out = vendor_props::read_standard(
            &self.engine,
            &self.info,
            properties,
            |p| self.code_for(p),
            &fmt,
        )
        .await?;
        if properties.contains(&TetherProperty::CaptureDestination) {
            let mut allowed = Vec::new();
            if self.capabilities.contains(CameraCapabilities::CARD_CAPTURE) {
                allowed.push(CaptureDestination::Card);
            }
            if self.sdram_capable {
                allowed.push(CaptureDestination::Host);
            }
            if self.sdram_capable && self.info.supports_op(op::INITIATE_CAPTURE_REC_IN_MEDIA) {
                allowed.push(CaptureDestination::Both);
            }
            let writable = allowed.len() > 1;
            out.push(vendor_props::destination_descriptor(
                self.destination(),
                &allowed,
                writable,
            ));
        }
        Ok(out)
    }

    async fn write_property(&self, property: TetherProperty, raw: PtpValue) -> PtpResult<()> {
        if property == TetherProperty::CaptureDestination {
            let Some(d) = vendor_props::destination_from_raw(&raw) else {
                return Err(PtpError::Unsupported("Unknown capture destination.".into()));
            };
            return self.set_capture_destination(d).await;
        }
        let Some(c) = self
            .code_for(property)
            .filter(|c| self.info.supports_prop(*c))
        else {
            return Err(cannot_set(property));
        };
        self.engine.set_device_prop_value(c, &raw).await
    }

    // MARK: Transfer

    async fn fetch_object(
        &self,
        object: &NewObject,
        progress: Option<ProgressFn>,
    ) -> PtpResult<(PtpObjectInfo, Vec<u8>)> {
        if !(object.in_sdram || object.handle == SDRAM_HANDLE) {
            return self.generic.fetch_object(object, progress).await;
        }
        // SDRAM objects: GetObjectInfo + GetObject. The object vanishes once
        // read, so DeleteImagesInSdram is not needed.
        let oi = self.engine.get_object_info(object.handle).await?;
        let data = self.engine.get_object(object.handle, None).await?;
        if let Some(p) = &progress {
            p(data.len(), Some(data.len()));
        }
        Ok((oi, data))
    }

    // MARK: Live view

    async fn start_live_view(&self, _quality: LiveViewQuality) -> PtpResult<()> {
        if !self.capabilities.contains(CameraCapabilities::LIVE_VIEW) {
            return Err(no_live_view());
        }
        if self.info.supports_prop(prop::LIVE_VIEW_PROHIBIT_CONDITION) {
            let v = self
                .engine
                .get_device_prop_value(prop::LIVE_VIEW_PROHIBIT_CONDITION, DataType::UINT32)
                .await?;
            if let Some(bits) = v.uint_value().filter(|&b| b != 0) {
                return Err(PtpError::VendorGate(prohibit_description(bits as u32)));
            }
        }
        run(&self.engine, op::START_LIVE_VIEW, &[], Some(15.0), false).await?;
        self.wait_until_ready().await?;
        lock(&self.state).live_view_on = true;
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
        let _ = self
            .engine
            .execute(PtpRequest::new(op::END_LIVE_VIEW, []))
            .await;
    }

    async fn next_live_view_frame(&self) -> PtpResult<Option<LiveViewFrame>> {
        if !lock(&self.state).live_view_on {
            return Ok(None);
        }
        let req = PtpRequest::new(op::GET_LIVE_VIEW_IMG, [])
            .expecting_large_data(true)
            .with_timeout(Duration::from_secs(5));
        let r = self.engine.execute(req).await?;
        match r.code {
            ResponseCode::OK => {}
            ResponseCode::DEVICE_BUSY => return Ok(None),
            code => {
                return Err(PtpError::Response {
                    op: op::GET_LIVE_VIEW_IMG,
                    code,
                    parameters: r.parameters,
                })
            }
        }
        // Header length varies (64/128/384 bytes by model); find the JPEG.
        let Some(jpeg) = jpeg_payload(&r.data_in) else {
            return Ok(None);
        };
        let mut s = lock(&self.state);
        s.frame_sequence += 1;
        Ok(Some(live_frame(jpeg.to_vec(), s.frame_sequence)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shutter_and_white_balance_tables() {
        assert_eq!(shutter_display(1 << 16 | 250), "1/250");
        assert_eq!(shutter_display(20 << 16 | 10), "2\"");
        assert_eq!(shutter_display(0xFFFF_FFFF), "Bulb");
        assert_eq!(white_balance_display(0x8011), "Shade");
        assert_eq!(white_balance_display(4), "Daylight");
    }

    #[test]
    fn prohibit_conditions_are_spelled_out() {
        assert_eq!(
            prohibit_description(0),
            "Live view is blocked by the camera."
        );
        let m = prohibit_description(1 << 17 | 1 << 3);
        assert!(m.contains("No lens attached"));
        assert!(m.contains("Condition bit 3"));
    }

    #[test]
    fn get_event_parser_stops_at_truncation() {
        let mut b = ByteBuffer::new();
        b.write_u16(3);
        b.write_u16(0x4002);
        b.write_u32(7);
        b.write_u16(0x4006); // truncated pair
        let ev = NikonHandler::parse_events(b.bytes()).unwrap();
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].parameters, vec![7]);
    }
}
