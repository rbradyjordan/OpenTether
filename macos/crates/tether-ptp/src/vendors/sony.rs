//! Sony Alpha: SDIO connect gate, property dump via 0x9209, half/full
//! shutter through control properties, fixed SDRAM handle, live-view object.
//! Ported from `SonyHandler.swift`.
//!
//! Constants are named after libgphoto2 `ptp.h` (`PTP_OC_SONY_*`,
//! `PTP_DPC_SONY_*`, `PTP_EC_SONY_*`). VERIFY marks the unconfirmed ones.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tether_types::{
    jpeg_payload, CameraCapabilities, CameraVendor, CaptureDestination, LiveViewFrame,
    LiveViewQuality,
};

use super::{cannot_set, live_frame, no_live_view, run, run_out};
use crate::device::property::format;
use crate::device::{
    vendor_props, CameraEvent, GenericPtpHandler, NewObject, PropertyChoice, PropertyDescriptor,
    PropertyForm, TetherProperty, VendorHandler,
};
use crate::ptp::transport::lock;
use crate::ptp::{
    ByteBuffer, DataType, DevicePropCode, OperationCode, ProgressFn, PropForm, PtpDeviceInfo,
    PtpEngine, PtpError, PtpEvent, PtpObjectInfo, PtpRequest, PtpResult, PtpValue,
};

/// Sony operation codes.
pub mod op {
    use crate::ptp::OperationCode as O;
    pub const SDIO_CONNECT: O = O(0x9201);
    pub const SDIO_GET_EXT_DEVICE_INFO: O = O(0x9202);
    pub const SDIO_SET_EXT_DEVICE_PROP_VALUE: O = O(0x9205);
    pub const SDIO_CONTROL_DEVICE: O = O(0x9207);
    pub const SDIO_GET_ALL_EXT_DEVICE_PROP_INFO: O = O(0x9209);
}

/// Sony device property codes and control values.
pub mod prop {
    use crate::ptp::DevicePropCode as P;
    pub const SHUTTER_SPEED: P = P(0xD20D);
    pub const COLOR_TEMPERATURE: P = P(0xD20F);
    pub const ASPECT_RATIO: P = P(0xD211);
    pub const FOCUS_FOUND: P = P(0xD213);
    pub const OBJECT_IN_MEMORY: P = P(0xD215);
    /// VERIFY: libgphoto2 PTP_DPC_SONY_BatteryLevel.
    pub const BATTERY_LEVEL: P = P(0xD218);
    pub const ISO: P = P(0xD21E);
    pub const LIVE_VIEW_STATUS: P = P(0xD221);
    /// VERIFY: 0xD222 is "Capture (save) destination" in some sniffs; unused until confirmed.
    pub const STILL_IMAGE_STORE_DESTINATION: P = P(0xD222);
    pub const SHUTTER_HALF_RELEASE: P = P(0xD2C1);
    pub const SHUTTER_RELEASE: P = P(0xD2C2);
    pub const AF_LOCK: P = P(0xD2C3);
    pub const MOVIE: P = P(0xD2C8);
    pub const STILL_IMAGE: P = P(0xD2C7);

    pub const ISO_AUTO: u32 = 0x00FF_FFFF;
    /// ObjectInMemory >= this means an image is waiting.
    pub const OBJECT_WAITING_THRESHOLD: u16 = 0x8000;
    /// Control values for the shutter properties. VERIFY: 2 = press, 1 = release.
    pub const PRESS: u16 = 2;
    pub const RELEASE: u16 = 1;
    /// FocusFound values. VERIFY: libgphoto2 waits for 3 (locked); 1 = searching, 2 = failed.
    pub const FOCUS_LOCKED: i64 = 3;
}

/// Sony event codes.
pub mod event {
    use crate::ptp::EventCode as E;
    pub const OBJECT_ADDED: E = E(0xC201);
    pub const OBJECT_REMOVED: E = E(0xC202);
    pub const PROPERTY_CHANGED: E = E(0xC203);
}

/// SDIOConnect phases and the extended-device-info version parameters.
pub const CONNECT_PHASES: [u32; 3] = [1, 2, 3];
/// VERIFY: libgphoto2 tries 0x12C (300) then 0xC8 (200).
pub const EXT_DEVICE_INFO_VERSION: u32 = 0x12C;
pub const EXT_DEVICE_INFO_VERSION_FALLBACK: u32 = 0xC8;

/// Fixed handles for the captured image and the live-view frame.
pub const SDRAM_HANDLE: u32 = 0xFFFF_C001;
pub const LIVE_VIEW_HANDLE: u32 = 0xFFFF_C002;

/// Sony white balance. VERIFY: libgphoto2 `sony_whitebalance`.
pub const WHITE_BALANCES: &[(i64, &str)] = &[
    (0x0002, "Auto"),
    (0x0004, "Daylight"),
    (0x0006, "Tungsten"),
    (0x0007, "Flash"),
    (0x8001, "Fluorescent (warm white)"),
    (0x8002, "Fluorescent (cool white)"),
    (0x8003, "Fluorescent (day white)"),
    (0x8004, "Fluorescent (daylight)"),
    (0x8010, "Cloudy"),
    (0x8011, "Shade"),
    (0x8012, "Color temperature"),
    (0x8020, "Custom 1"),
    (0x8021, "Custom 2"),
    (0x8022, "Custom 3"),
    (0x8023, "Custom"),
    (0x8030, "Underwater auto"),
];

pub fn shutter_display(v: u32) -> String {
    if v == 0 || v == 0xFFFF_FFFF {
        return "Bulb".into();
    }
    format::shutter_fraction(i64::from(v >> 16), i64::from(v & 0xFFFF))
}

pub fn iso_display(v: i64) -> String {
    if v == i64::from(prop::ISO_AUTO) {
        return "Auto".into();
    }
    // Bit 24+ carries the multi-frame-NR flavour; the ISO is the low 24 bits.
    format::iso(v & 0x00FF_FFFF)
}

pub fn property_for(code: DevicePropCode) -> Option<TetherProperty> {
    match code {
        prop::SHUTTER_SPEED => Some(TetherProperty::ShutterSpeed),
        prop::ISO => Some(TetherProperty::Iso),
        prop::BATTERY_LEVEL => Some(TetherProperty::BatteryLevel),
        prop::COLOR_TEMPERATURE => Some(TetherProperty::ColorTemperature),
        prop::LIVE_VIEW_STATUS => Some(TetherProperty::LiveViewEnabled),
        _ => GenericPtpHandler::standard_property(code),
    }
}

pub fn code_for(p: TetherProperty) -> Option<DevicePropCode> {
    match p {
        TetherProperty::ShutterSpeed => Some(prop::SHUTTER_SPEED),
        TetherProperty::Iso => Some(prop::ISO),
        TetherProperty::BatteryLevel => Some(prop::BATTERY_LEVEL),
        TetherProperty::ColorTemperature => Some(prop::COLOR_TEMPERATURE),
        TetherProperty::LiveViewEnabled => Some(prop::LIVE_VIEW_STATUS),
        TetherProperty::CaptureDestination => None,
        _ => GenericPtpHandler::standard_code(p),
    }
}

pub fn display(p: TetherProperty, v: &PtpValue) -> String {
    match p {
        TetherProperty::ShutterSpeed => shutter_display(v.uint_value().unwrap_or(0) as u32),
        TetherProperty::Iso => iso_display(v.int_value().unwrap_or(0)),
        TetherProperty::WhiteBalance => {
            let n = v.int_value();
            WHITE_BALANCES
                .iter()
                .find(|(k, _)| Some(*k) == n)
                .map_or_else(
                    || format::white_balance_standard(n.unwrap_or(0)),
                    |(_, s)| (*s).to_string(),
                )
        }
        TetherProperty::ColorTemperature => format!("{} K", v.int_value().unwrap_or(0)),
        _ => GenericPtpHandler::format(p, v),
    }
}

/// One Sony extended DevicePropDesc: the standard dataset plus an
/// `is_enabled` byte after get/set, and (on newer firmware) a second
/// enumeration list with the values the camera will accept for writing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SonyPropDesc {
    pub code: DevicePropCode,
    pub data_type: DataType,
    pub is_writable: bool,
    pub is_enabled: bool,
    pub factory_default: PtpValue,
    pub current: PtpValue,
    pub form: PropForm,
    /// The set-able values when the camera sent a second list.
    pub settable: Option<Vec<PtpValue>>,
}

impl SonyPropDesc {
    pub fn new(
        code: DevicePropCode,
        data_type: DataType,
        is_writable: bool,
        current: PtpValue,
        form: PropForm,
    ) -> Self {
        Self {
            code,
            data_type,
            is_writable,
            is_enabled: true,
            factory_default: current.clone(),
            current,
            form,
            settable: None,
        }
    }

    pub fn choices(&self) -> Option<&[PtpValue]> {
        if let Some(s) = self.settable.as_deref().filter(|s| !s.is_empty()) {
            return Some(s);
        }
        match &self.form {
            PropForm::Enumeration(v) => Some(v),
            _ => None,
        }
    }

    /// Parses an SDIOGetAllExtDevicePropInfo payload: UInt64 count, then
    /// records. Tries the two-list layout first and falls back to the
    /// single-list layout when the buffer does not divide cleanly.
    /// VERIFY: libgphoto2 `ptp_unpack_Sony_DPD` / `ptp_sony_getalldevicepropdesc`.
    pub fn parse_all(data: &[u8]) -> PtpResult<Vec<SonyPropDesc>> {
        if let Ok(two) = Self::parse_all_layout(data, true) {
            return Ok(two);
        }
        Self::parse_all_layout(data, false)
    }

    pub fn parse_all_layout(data: &[u8], two_lists: bool) -> PtpResult<Vec<SonyPropDesc>> {
        let mut b = ByteBuffer::from(data);
        let count = b.read_u64()?;
        let mut out = Vec::new();
        for _ in 0..count {
            out.push(Self::read(&mut b, two_lists)?);
        }
        if !b.is_at_end() {
            return Err(PtpError::Malformed(format!(
                "Sony property dump has {} trailing bytes",
                b.remaining()
            )));
        }
        Ok(out)
    }

    pub fn read(b: &mut ByteBuffer, two_lists: bool) -> PtpResult<SonyPropDesc> {
        let code = DevicePropCode(b.read_u16()?);
        let data_type = DataType(b.read_u16()?);
        let is_writable = b.read_u8()? == 1;
        let is_enabled = b.read_u8()? != 0;
        let factory_default = PtpValue::read(data_type, b)?;
        let current = PtpValue::read(data_type, b)?;
        let (form, settable) = match b.read_u8()? {
            1 => {
                let min = PtpValue::read(data_type, b)?;
                let max = PtpValue::read(data_type, b)?;
                let step = PtpValue::read(data_type, b)?;
                (PropForm::Range { min, max, step }, None)
            }
            2 => {
                let n = b.read_u16()?;
                let mut vals = Vec::new();
                for _ in 0..n {
                    vals.push(PtpValue::read(data_type, b)?);
                }
                let settable = if two_lists {
                    let n2 = b.read_u16()?;
                    let mut second = Vec::new();
                    for _ in 0..n2 {
                        second.push(PtpValue::read(data_type, b)?);
                    }
                    Some(second)
                } else {
                    None
                };
                (PropForm::Enumeration(vals), settable)
            }
            _ => (PropForm::None, None),
        };
        Ok(SonyPropDesc {
            code,
            data_type,
            is_writable,
            is_enabled,
            factory_default,
            current,
            form,
            settable,
        })
    }

    pub fn encoded(&self) -> Vec<u8> {
        let mut b = ByteBuffer::new();
        b.write_u16(self.code.0);
        b.write_u16(self.data_type.0);
        b.write_u8(u8::from(self.is_writable));
        b.write_u8(u8::from(self.is_enabled));
        self.factory_default.write(&mut b);
        self.current.write(&mut b);
        match &self.form {
            PropForm::None => b.write_u8(0),
            PropForm::Range { min, max, step } => {
                b.write_u8(1);
                min.write(&mut b);
                max.write(&mut b);
                step.write(&mut b);
            }
            PropForm::Enumeration(vals) => {
                b.write_u8(2);
                b.write_u16(vals.len() as u16);
                vals.iter().for_each(|v| v.write(&mut b));
                if let Some(s) = &self.settable {
                    b.write_u16(s.len() as u16);
                    s.iter().for_each(|v| v.write(&mut b));
                }
            }
        }
        b.into_bytes()
    }

    /// Encodes a whole dump (UInt64 count + records).
    pub fn encode_all(descs: &[SonyPropDesc]) -> Vec<u8> {
        let mut b = ByteBuffer::new();
        b.write_u64(descs.len() as u64);
        for d in descs {
            b.write_bytes(&d.encoded());
        }
        b.into_bytes()
    }
}

struct SonyState {
    props: BTreeMap<DevicePropCode, SonyPropDesc>,
    destination: CaptureDestination,
    live_view_on: bool,
    frame_sequence: u64,
    focus_timeout: Duration,
    focus_poll_interval: Duration,
}

/// Sony Alpha: SDIO connect gate, property dump via 0x9209, half/full
/// shutter through control properties, fixed SDRAM handle, live view object.
pub struct SonyHandler {
    pub engine: Arc<PtpEngine>,
    pub info: PtpDeviceInfo,
    capabilities: CameraCapabilities,
    generic: GenericPtpHandler,
    state: Mutex<SonyState>,
}

impl SonyHandler {
    pub fn new(engine: Arc<PtpEngine>, info: PtpDeviceInfo) -> Self {
        use CameraCapabilities as C;
        let generic = GenericPtpHandler::new(engine.clone(), info.clone(), None);
        let mut caps = C::empty();
        let sdio = info.supports_op(op::SDIO_CONNECT);
        if sdio && info.supports_op(op::SDIO_CONTROL_DEVICE) {
            caps |= C::REMOTE_CAPTURE | C::CARD_CAPTURE | C::SDRAM_CAPTURE | C::AUTOFOCUS;
            caps |= C::LIVE_VIEW;
        } else if info.supports_op(OperationCode::INITIATE_CAPTURE) {
            caps |= C::REMOTE_CAPTURE | C::CARD_CAPTURE;
        }
        if sdio && info.supports_op(op::SDIO_SET_EXT_DEVICE_PROP_VALUE) {
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
            state: Mutex::new(SonyState {
                props: BTreeMap::new(),
                destination: CaptureDestination::Both,
                live_view_on: false,
                frame_sequence: 0,
                focus_timeout: Duration::from_secs(2),
                focus_poll_interval: Duration::from_millis(100),
            }),
        }
    }

    /// How long capture waits for FocusFound after the half-press.
    pub fn set_focus_timeout(&self, d: Duration) {
        lock(&self.state).focus_timeout = d;
    }

    pub fn set_focus_poll_interval(&self, d: Duration) {
        lock(&self.state).focus_poll_interval = d;
    }

    /// The last property dump.
    pub fn props(&self) -> BTreeMap<DevicePropCode, SonyPropDesc> {
        lock(&self.state).props.clone()
    }

    pub async fn control(&self, code: DevicePropCode, value: u16) -> PtpResult<()> {
        run_out(
            &self.engine,
            op::SDIO_CONTROL_DEVICE,
            &[u32::from(code.0)],
            PtpValue::UInt16(value).encoded(),
        )
        .await
        .map(|_| ())
    }

    /// Polls FocusFound until locked or the timeout passes (then shoots anyway).
    pub async fn wait_for_focus(&self) -> PtpResult<()> {
        if !self.info.supports_op(op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO) {
            return Ok(());
        }
        let (timeout, interval) = {
            let s = lock(&self.state);
            (s.focus_timeout, s.focus_poll_interval)
        };
        let deadline = Instant::now() + timeout;
        loop {
            let dump = self.refresh_props().await?;
            if dump
                .get(&prop::FOCUS_FOUND)
                .and_then(|d| d.current.int_value())
                == Some(prop::FOCUS_LOCKED)
            {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Ok(());
            }
            tokio::time::sleep(interval).await;
        }
    }

    pub async fn refresh_props(&self) -> PtpResult<BTreeMap<DevicePropCode, SonyPropDesc>> {
        let r = run(
            &self.engine,
            op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO,
            &[],
            None,
            true,
        )
        .await?;
        let parsed = SonyPropDesc::parse_all(&r.data_in)?;
        let map: BTreeMap<_, _> = parsed.into_iter().map(|d| (d.code, d)).collect();
        lock(&self.state).props = map.clone();
        Ok(map)
    }

    pub fn descriptor(
        p: TetherProperty,
        desc: &SonyPropDesc,
        writable: bool,
    ) -> PropertyDescriptor {
        let form = match (desc.choices(), &desc.form) {
            (Some(vals), _) if !vals.is_empty() => PropertyForm::Choices(
                vals.iter()
                    .map(|v| PropertyChoice::new(v.clone(), display(p, v)))
                    .collect(),
            ),
            (_, PropForm::Range { min, max, step }) => PropertyForm::Range {
                min: min.int_value().unwrap_or(0) as f64,
                max: max.int_value().unwrap_or(0) as f64,
                step: step.int_value().unwrap_or(1) as f64,
            },
            _ => PropertyForm::Other,
        };
        PropertyDescriptor::new(
            p,
            desc.current.clone(),
            display(p, &desc.current),
            writable && desc.is_writable && desc.is_enabled,
            form,
        )
    }
}

#[async_trait]
impl VendorHandler for SonyHandler {
    fn vendor(&self) -> CameraVendor {
        CameraVendor::Sony
    }

    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities
    }

    fn event_poll_interval(&self) -> Duration {
        Duration::from_millis(200)
    }

    // MARK: Gate

    async fn prepare(&self) -> PtpResult<()> {
        if !self.info.supports_op(op::SDIO_CONNECT) {
            return Err(PtpError::VendorGate(
                "Set USB Connection to PC Remote on the camera (Setup → USB Connection / PC Remote Function) and reconnect.".into(),
            ));
        }
        let e = &self.engine;
        run(e, op::SDIO_CONNECT, &[CONNECT_PHASES[0], 0, 0], None, false).await?;
        run(e, op::SDIO_CONNECT, &[CONNECT_PHASES[1], 0, 0], None, false).await?;
        if self.info.supports_op(op::SDIO_GET_EXT_DEVICE_INFO) {
            let r = e
                .execute(PtpRequest::new(
                    op::SDIO_GET_EXT_DEVICE_INFO,
                    [EXT_DEVICE_INFO_VERSION],
                ))
                .await?;
            if !r.is_ok() {
                run(
                    e,
                    op::SDIO_GET_EXT_DEVICE_INFO,
                    &[EXT_DEVICE_INFO_VERSION_FALLBACK],
                    None,
                    false,
                )
                .await?;
            }
        }
        run(e, op::SDIO_CONNECT, &[CONNECT_PHASES[2], 0, 0], None, false).await?;
        let _ = self.refresh_props().await;
        Ok(())
    }

    async fn teardown(&self) {
        self.stop_live_view().await;
    }

    // MARK: Capture

    async fn set_capture_destination(&self, d: CaptureDestination) -> PtpResult<()> {
        if d == CaptureDestination::Host {
            // VERIFY: "Still Image Save Destination: PC only" may be 0xD222; until
            // confirmed we only offer card and card+host.
            return Err(PtpError::Unsupported(
                "Set “Still Img. Save Dest.” to PC only on the camera itself; this app can only choose Card or Card + Mac here.".into(),
            ));
        }
        lock(&self.state).destination = d;
        Ok(())
    }

    async fn capture(&self, autofocus: bool) -> PtpResult<()> {
        if !self.info.supports_op(op::SDIO_CONTROL_DEVICE) {
            if self.info.supports_op(OperationCode::INITIATE_CAPTURE) {
                return self.engine.initiate_capture(0, None).await;
            }
            return Err(PtpError::Unsupported(
                "This Sony does not support remote capture over PTP.".into(),
            ));
        }
        if autofocus {
            self.control(prop::SHUTTER_HALF_RELEASE, prop::PRESS)
                .await?;
            self.wait_for_focus().await?;
        }
        self.control(prop::SHUTTER_RELEASE, prop::PRESS).await?;
        self.control(prop::SHUTTER_RELEASE, prop::RELEASE).await?;
        if autofocus {
            self.control(prop::SHUTTER_HALF_RELEASE, prop::RELEASE)
                .await?;
        }
        Ok(())
    }

    // MARK: Events

    async fn poll_events(&self) -> PtpResult<Vec<CameraEvent>> {
        if !self.info.supports_op(op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO) {
            return Ok(Vec::new());
        }
        let before = self.props();
        let now = self.refresh_props().await?;
        let mut out = Vec::new();
        if let Some(waiting) = now
            .get(&prop::OBJECT_IN_MEMORY)
            .and_then(|d| d.current.uint_value())
        {
            if waiting >= u64::from(prop::OBJECT_WAITING_THRESHOLD) {
                out.push(CameraEvent::ObjectAdded(NewObject {
                    in_sdram: true,
                    ..NewObject::new(SDRAM_HANDLE)
                }));
            }
        }
        for (code, desc) in &now {
            if before.get(code).map(|d| &d.current) != Some(&desc.current) {
                if let Some(p) =
                    property_for(*code).filter(|p| *p != TetherProperty::LiveViewEnabled)
                {
                    out.push(CameraEvent::PropertyChanged(Some(p)));
                }
            }
        }
        Ok(out)
    }

    async fn translate(&self, e: &PtpEvent) -> Option<CameraEvent> {
        match e.code {
            event::OBJECT_ADDED => {
                let h = e.parameters.first().copied().unwrap_or(SDRAM_HANDLE);
                Some(CameraEvent::ObjectAdded(NewObject {
                    in_sdram: h == SDRAM_HANDLE || h == 0,
                    ..NewObject::new(if h == 0 { SDRAM_HANDLE } else { h })
                }))
            }
            event::OBJECT_REMOVED => e
                .parameters
                .first()
                .map(|&handle| CameraEvent::ObjectRemoved { handle }),
            // Values changed; the next poll picks them up.
            event::PROPERTY_CHANGED => Some(CameraEvent::PropertyChanged(
                e.parameters
                    .first()
                    .and_then(|&c| property_for(DevicePropCode(c as u16))),
            )),
            _ => self.generic.translate(e).await,
        }
    }

    // MARK: Properties

    async fn read_properties(
        &self,
        properties: &[TetherProperty],
    ) -> PtpResult<Vec<PropertyDescriptor>> {
        let dump = if self.info.supports_op(op::SDIO_GET_ALL_EXT_DEVICE_PROP_INFO) {
            self.refresh_props().await?
        } else {
            BTreeMap::new()
        };
        let writable = self
            .capabilities
            .contains(CameraCapabilities::PROPERTY_CONTROL);
        let mut out = Vec::new();
        for &p in properties {
            if p == TetherProperty::CaptureDestination {
                out.push(vendor_props::destination_descriptor(
                    lock(&self.state).destination,
                    &[CaptureDestination::Card, CaptureDestination::Both],
                    true,
                ));
                continue;
            }
            let Some(desc) = code_for(p).and_then(|c| dump.get(&c)) else {
                continue;
            };
            out.push(Self::descriptor(p, desc, writable));
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
        let Some(code) = code_for(property) else {
            return Err(cannot_set(property));
        };
        if !self.info.supports_op(op::SDIO_SET_EXT_DEVICE_PROP_VALUE) {
            return self.engine.set_device_prop_value(code, &raw).await;
        }
        run_out(
            &self.engine,
            op::SDIO_SET_EXT_DEVICE_PROP_VALUE,
            &[u32::from(code.0)],
            raw.encoded(),
        )
        .await
        .map(|_| ())
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
        lock(&self.state).live_view_on = true;
        Ok(())
    }

    async fn stop_live_view(&self) {
        lock(&self.state).live_view_on = false;
    }

    async fn next_live_view_frame(&self) -> PtpResult<Option<LiveViewFrame>> {
        if !lock(&self.state).live_view_on {
            return Ok(None);
        }
        let r = self
            .engine
            .execute(PtpRequest::new(
                OperationCode::GET_OBJECT_INFO,
                [LIVE_VIEW_HANDLE],
            ))
            .await?;
        if !r.is_ok() {
            return Ok(None); // not streaming yet
        }
        let req = PtpRequest::new(OperationCode::GET_OBJECT, [LIVE_VIEW_HANDLE])
            .expecting_large_data(true)
            .with_timeout(Duration::from_secs(5));
        let r2 = self.engine.execute(req).await?;
        if !r2.is_ok() {
            return Ok(None);
        }
        let Some(jpeg) = jpeg_payload(&r2.data_in) else {
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
    fn value_tables() {
        assert_eq!(shutter_display(0), "Bulb");
        assert_eq!(shutter_display(1 << 16 | 4000), "1/4000");
        assert_eq!(iso_display(i64::from(prop::ISO_AUTO)), "Auto");
        assert_eq!(iso_display(0x0100_0C80), "3200"); // multi-frame NR flag stripped
        assert_eq!(
            display(TetherProperty::WhiteBalance, &PtpValue::UInt16(0x8030)),
            "Underwater auto"
        );
        assert_eq!(
            display(TetherProperty::WhiteBalance, &PtpValue::UInt16(5)),
            "Fluorescent"
        );
        assert_eq!(
            display(TetherProperty::ColorTemperature, &PtpValue::UInt16(5600)),
            "5600 K"
        );
    }
}
