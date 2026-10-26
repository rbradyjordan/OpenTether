//! The per-vendor behaviour trait, the generic PTP fallback handler and the
//! registry that picks a handler for a camera.

use std::any::Any;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::Duration;

use async_trait::async_trait;
use tether_types::{
    CameraCapabilities, CameraVendor, CaptureDestination, LiveViewFrame, LiveViewQuality,
    TransportKind,
};

use super::detect_vendor;
use super::property::{format, PropertyChoice, PropertyDescriptor, PropertyForm, TetherProperty};
use super::support::ObjectHandleDiffer;
use crate::ptp::transport::lock;
use crate::ptp::{
    DevicePropCode, EventCode, OperationCode, ProgressFn, PropForm, PtpDeviceInfo,
    PtpDevicePropDesc, PtpEngine, PtpError, PtpEvent, PtpObjectInfo, PtpResult, PtpValue,
};

/// A freshly announced object on the camera (ObjectAdded or vendor equivalent).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewObject {
    pub handle: u32,
    pub storage_id: u32,
    pub info: Option<PtpObjectInfo>,
    /// True when the object lives in the camera's RAM buffer and must be
    /// fetched now (SDRAM handles are transient).
    pub in_sdram: bool,
}

impl NewObject {
    pub fn new(handle: u32) -> Self {
        Self {
            handle,
            storage_id: 0,
            info: None,
            in_sdram: false,
        }
    }
}

/// Vendor-neutral events the capture loop consumes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CameraEvent {
    ObjectAdded(NewObject),
    ObjectRemoved { handle: u32 },
    PropertyChanged(Option<TetherProperty>),
    CaptureComplete,
    StorageChanged,
    CameraBusy(bool),
    ShutterPressed,
    Warning(String),
    Disconnected,
    Raw(PtpEvent),
}

/// Outcome of a touch focus, as the camera reported it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FocusResult {
    Focused,
    Failed,
    /// The camera gave no report (older bodies, or it never answered).
    Unconfirmed,
}

impl FocusResult {
    /// Raw values match the iOS enum.
    pub fn raw(self) -> &'static str {
        match self {
            Self::Focused => "focused",
            Self::Failed => "failed",
            Self::Unconfirmed => "unconfirmed",
        }
    }
}

/// Per-vendor behaviour on top of the generic PTP engine. One instance per
/// connected camera, shared as `Arc<dyn VendorHandler>`; implementations
/// keep their mutable state behind interior locks.
///
/// The handler owns the vendor gates (Canon PC mode + two-stage shutter,
/// Nikon ChangeApplicationMode, Sony SDIO connect, Fuji tether mode), the
/// mapping from `TetherProperty` to vendor codes, event polling for vendors
/// that do not push events, and live view.
///
/// `Any` is a supertrait so callers (and tests) can downcast an
/// `Arc<dyn VendorHandler>` to the concrete handler (see `handler_is`).
#[async_trait]
pub trait VendorHandler: Any + Send + Sync {
    fn vendor(&self) -> CameraVendor;
    fn capabilities(&self) -> CameraCapabilities;

    /// Interval for `poll_events` when the camera does not push events.
    fn event_poll_interval(&self) -> Duration {
        Duration::from_millis(250)
    }

    /// Run the vendor gate and put the body into remote-control mode.
    async fn prepare(&self) -> PtpResult<()>;
    async fn teardown(&self);

    async fn set_capture_destination(&self, destination: CaptureDestination) -> PtpResult<()>;
    /// Trigger a still capture. Two-stage vendors handle AF inside.
    async fn capture(&self, autofocus: bool) -> PtpResult<()>;

    /// For polled vendors: ask the camera what happened since last time.
    async fn poll_events(&self) -> PtpResult<Vec<CameraEvent>> {
        Ok(Vec::new())
    }
    /// For pushed events: translate a transport event. None = ignore.
    async fn translate(&self, event: &PtpEvent) -> Option<CameraEvent>;

    async fn read_properties(
        &self,
        properties: &[TetherProperty],
    ) -> PtpResult<Vec<PropertyDescriptor>>;
    async fn write_property(&self, property: TetherProperty, raw: PtpValue) -> PtpResult<()>;

    /// Download one object (ObjectInfo + bytes). Vendors with SDRAM-only
    /// handles or their own partial-object opcode override this.
    async fn fetch_object(
        &self,
        object: &NewObject,
        progress: Option<ProgressFn>,
    ) -> PtpResult<(PtpObjectInfo, Vec<u8>)>;

    async fn start_live_view(&self, _quality: LiveViewQuality) -> PtpResult<()> {
        Err(PtpError::Unsupported(
            "Live view is not available on this camera.".into(),
        ))
    }
    async fn stop_live_view(&self) {}
    /// Next frame, or None when none is ready yet.
    async fn next_live_view_frame(&self) -> PtpResult<Option<LiveViewFrame>> {
        Ok(None)
    }

    /// Write a star rating back to the camera when it supports it.
    async fn set_rating(&self, _handle: u32, _stars: i32) -> PtpResult<()> {
        Err(PtpError::Unsupported(
            "Rating is not supported on this camera.".into(),
        ))
    }
    /// Focus once at a point of the live-view image, 0…1 from the top left,
    /// returning what the camera reported.
    async fn focus(&self, _x: f64, _y: f64) -> PtpResult<FocusResult> {
        Err(PtpError::Unsupported(
            "Touch focus is not available on this camera.".into(),
        ))
    }
    /// AF ON at a point until `stop_tracking_focus` (AF OFF), in the camera's own AF mode.
    async fn start_tracking_focus(&self, _x: f64, _y: f64) -> PtpResult<()> {
        Err(PtpError::Unsupported(
            "Touch focus is not available on this camera.".into(),
        ))
    }
    async fn stop_tracking_focus(&self) {}
}

/// True when `handler` is a `T` (Swift's `handler is T`).
pub fn handler_is<T: VendorHandler>(handler: &dyn VendorHandler) -> bool {
    let any: &dyn Any = handler;
    any.is::<T>()
}

/// Downcast to the concrete handler.
pub fn handler_downcast<T: VendorHandler>(handler: &dyn VendorHandler) -> Option<&T> {
    let any: &dyn Any = handler;
    any.downcast_ref::<T>()
}

/// Generic PTP: watch for ObjectAdded, download, and InitiateCapture when the
/// camera advertises it. This is the safe baseline for every brand without
/// a dedicated handler (Hasselblad, Sigma, Pentax, Samsung, compacts) and for
/// bodies whose vendor mode is off: new files are found from the camera's
/// own events and, as a safety net, by polling the card.
pub struct GenericPtpHandler {
    pub engine: Arc<PtpEngine>,
    pub info: PtpDeviceInfo,
    vendor: CameraVendor,
    capabilities: CameraCapabilities,
    prop_types: Mutex<HashMap<DevicePropCode, crate::ptp::DataType>>,
    differ: ObjectHandleDiffer,
    /// Shown once on connect, e.g. "set USB mode to PC Remote for full control".
    setup_hint: Mutex<Option<String>>,
}

impl GenericPtpHandler {
    pub fn new(engine: Arc<PtpEngine>, info: PtpDeviceInfo, setup_hint: Option<String>) -> Self {
        let vendor = detect_vendor(&info);
        let mut caps = CameraCapabilities::EVENT_PUSH | CameraCapabilities::IMPORT_ONLY;
        if info.supports_op(OperationCode::INITIATE_CAPTURE) {
            caps.insert(CameraCapabilities::REMOTE_CAPTURE);
            caps.insert(CameraCapabilities::CARD_CAPTURE);
            caps.remove(CameraCapabilities::IMPORT_ONLY);
        }
        if info.supports_op(OperationCode::GET_PARTIAL_OBJECT) {
            caps.insert(CameraCapabilities::PARTIAL_TRANSFER);
        }
        if info.supports_op(OperationCode::GET_THUMB) {
            caps.insert(CameraCapabilities::THUMBNAILS);
        }
        if info.supports_op(OperationCode::GET_DEVICE_PROP_DESC)
            && !info.device_properties_supported.is_empty()
        {
            caps.insert(CameraCapabilities::PROPERTY_CONTROL);
        }
        Self {
            engine,
            info,
            vendor,
            capabilities: caps,
            prop_types: Mutex::new(HashMap::new()),
            differ: ObjectHandleDiffer::default(),
            setup_hint: Mutex::new(setup_hint),
        }
    }

    pub fn standard_property(code: DevicePropCode) -> Option<TetherProperty> {
        use TetherProperty as P;
        Some(match code {
            DevicePropCode::F_NUMBER => P::Aperture,
            DevicePropCode::EXPOSURE_TIME => P::ShutterSpeed,
            DevicePropCode::EXPOSURE_INDEX => P::Iso,
            DevicePropCode::EXPOSURE_BIAS_COMPENSATION => P::ExposureCompensation,
            DevicePropCode::WHITE_BALANCE => P::WhiteBalance,
            DevicePropCode::EXPOSURE_PROGRAM_MODE => P::ExposureProgram,
            DevicePropCode::STILL_CAPTURE_MODE => P::DriveMode,
            DevicePropCode::EXPOSURE_METERING_MODE => P::MeteringMode,
            DevicePropCode::FOCUS_MODE => P::FocusMode,
            DevicePropCode::COMPRESSION_SETTING => P::ImageQuality,
            DevicePropCode::IMAGE_SIZE => P::ImageSize,
            DevicePropCode::BATTERY_LEVEL => P::BatteryLevel,
            DevicePropCode::FLASH_MODE => P::FlashMode,
            _ => return None,
        })
    }

    pub fn standard_code(p: TetherProperty) -> Option<DevicePropCode> {
        use TetherProperty as P;
        Some(match p {
            P::Aperture => DevicePropCode::F_NUMBER,
            P::ShutterSpeed => DevicePropCode::EXPOSURE_TIME,
            P::Iso => DevicePropCode::EXPOSURE_INDEX,
            P::ExposureCompensation => DevicePropCode::EXPOSURE_BIAS_COMPENSATION,
            P::WhiteBalance => DevicePropCode::WHITE_BALANCE,
            P::ExposureProgram => DevicePropCode::EXPOSURE_PROGRAM_MODE,
            P::DriveMode => DevicePropCode::STILL_CAPTURE_MODE,
            P::MeteringMode => DevicePropCode::EXPOSURE_METERING_MODE,
            P::FocusMode => DevicePropCode::FOCUS_MODE,
            P::ImageQuality => DevicePropCode::COMPRESSION_SETTING,
            P::ImageSize => DevicePropCode::IMAGE_SIZE,
            P::BatteryLevel => DevicePropCode::BATTERY_LEVEL,
            P::FlashMode => DevicePropCode::FLASH_MODE,
            _ => return None,
        })
    }

    /// Display formatting for the standard PTP encodings.
    pub fn format(p: TetherProperty, v: &PtpValue) -> String {
        let Some(n) = v.int_value() else {
            return v
                .string_value()
                .map(str::to_string)
                .unwrap_or_else(|| v.to_string());
        };
        match p {
            TetherProperty::Aperture => format::aperture(n),
            TetherProperty::ShutterSpeed => format::shutter_ten_thousandths(n),
            TetherProperty::Iso => format::iso(n),
            TetherProperty::ExposureCompensation => format::exposure_compensation(n),
            TetherProperty::WhiteBalance => format::white_balance_standard(n),
            TetherProperty::BatteryLevel => format::battery(n),
            _ => n.to_string(),
        }
    }

    /// Descriptor from a DevicePropDesc, formatted with `fmt` (default: `format`).
    pub fn descriptor(
        p: TetherProperty,
        desc: &PtpDevicePropDesc,
        fmt: Option<&PropertyFormatter>,
    ) -> PropertyDescriptor {
        let fmt = |p: TetherProperty, v: &PtpValue| match fmt {
            Some(f) => f(p, v),
            None => Self::format(p, v),
        };
        let form = match &desc.form {
            PropForm::Enumeration(vals) => PropertyForm::Choices(
                vals.iter()
                    .map(|v| PropertyChoice::new(v.clone(), fmt(p, v)))
                    .collect(),
            ),
            PropForm::Range { min, max, step } => PropertyForm::Range {
                min: min.int_value().unwrap_or(0) as f64,
                max: max.int_value().unwrap_or(0) as f64,
                step: step.int_value().unwrap_or(1) as f64,
            },
            PropForm::None => PropertyForm::Other,
        };
        PropertyDescriptor::new(
            p,
            desc.current.clone(),
            fmt(p, &desc.current),
            desc.is_writable,
            form,
        )
    }
}

#[async_trait]
impl VendorHandler for GenericPtpHandler {
    fn vendor(&self) -> CameraVendor {
        self.vendor
    }

    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities
    }

    fn event_poll_interval(&self) -> Duration {
        Duration::from_millis(1500)
    }

    async fn prepare(&self) -> PtpResult<()> {
        if self.info.supports_op(OperationCode::GET_OBJECT_HANDLES) {
            self.differ.seed(&self.engine).await;
        }
        Ok(())
    }

    async fn teardown(&self) {}

    /// Card polling catches bodies that never send ObjectAdded; duplicates of
    /// pushed events are dropped by the session.
    async fn poll_events(&self) -> PtpResult<Vec<CameraEvent>> {
        let mut out = Vec::new();
        if let Some(hint) = lock(&self.setup_hint).take() {
            out.push(CameraEvent::Warning(hint));
        }
        if self.info.supports_op(OperationCode::GET_OBJECT_HANDLES) && self.differ.is_seeded() {
            out.extend(self.differ.poll(&self.engine).await?);
        }
        Ok(out)
    }

    async fn set_capture_destination(&self, destination: CaptureDestination) -> PtpResult<()> {
        if destination != CaptureDestination::Card {
            return Err(PtpError::Unsupported(
                "This camera can only capture to its card.".into(),
            ));
        }
        Ok(())
    }

    async fn capture(&self, _autofocus: bool) -> PtpResult<()> {
        if !self.info.supports_op(OperationCode::INITIATE_CAPTURE) {
            return Err(PtpError::Unsupported(
                "This camera does not support remote capture over PTP.".into(),
            ));
        }
        self.engine.initiate_capture(0, None).await
    }

    async fn translate(&self, event: &PtpEvent) -> Option<CameraEvent> {
        let first = event.parameters.first().copied();
        match event.code {
            EventCode::OBJECT_ADDED | EventCode::REQUEST_OBJECT_TRANSFER => match first {
                Some(h) if h != 0 => Some(CameraEvent::ObjectAdded(NewObject::new(h))),
                _ => None,
            },
            EventCode::OBJECT_REMOVED => first.map(|handle| CameraEvent::ObjectRemoved { handle }),
            EventCode::DEVICE_PROP_CHANGED => {
                Some(CameraEvent::PropertyChanged(first.and_then(|c| {
                    Self::standard_property(DevicePropCode(c as u16))
                })))
            }
            EventCode::CAPTURE_COMPLETE => Some(CameraEvent::CaptureComplete),
            EventCode::STORE_ADDED
            | EventCode::STORE_REMOVED
            | EventCode::STORAGE_INFO_CHANGED
            | EventCode::STORE_FULL => Some(CameraEvent::StorageChanged),
            EventCode::DEVICE_RESET => Some(CameraEvent::Disconnected),
            _ => Some(CameraEvent::Raw(event.clone())),
        }
    }

    async fn read_properties(
        &self,
        properties: &[TetherProperty],
    ) -> PtpResult<Vec<PropertyDescriptor>> {
        let mut out = Vec::new();
        for &p in properties {
            let Some(code) = Self::standard_code(p).filter(|c| self.info.supports_prop(*c)) else {
                continue;
            };
            let desc = self.engine.get_device_prop_desc(code).await?;
            lock(&self.prop_types).insert(code, desc.data_type);
            out.push(Self::descriptor(p, &desc, None));
        }
        Ok(out)
    }

    async fn write_property(&self, property: TetherProperty, raw: PtpValue) -> PtpResult<()> {
        let Some(code) = Self::standard_code(property).filter(|c| self.info.supports_prop(*c))
        else {
            return Err(PtpError::Unsupported(format!(
                "{} cannot be set on this camera.",
                property.display_name()
            )));
        };
        self.engine.set_device_prop_value(code, &raw).await
    }

    async fn fetch_object(
        &self,
        object: &NewObject,
        progress: Option<ProgressFn>,
    ) -> PtpResult<(PtpObjectInfo, Vec<u8>)> {
        let info = match &object.info {
            Some(known) => known.clone(),
            None => self.engine.get_object_info(object.handle).await?,
        };
        let data = self
            .engine
            .download(object.handle, Some(info.object_compressed_size), progress)
            .await?;
        Ok((info, data))
    }
}

/// Display formatter for a property value.
pub type PropertyFormatter = dyn Fn(TetherProperty, &PtpValue) -> String + Send + Sync;

/// Builds a handler for a camera.
pub type HandlerFactory =
    Arc<dyn Fn(Arc<PtpEngine>, PtpDeviceInfo) -> Arc<dyn VendorHandler> + Send + Sync>;

/// Picks the handler for a camera. Vendor modules register themselves at
/// startup (`vendors::install_built_ins()`); anything unregistered gets the
/// generic handler, so an unknown body still imports.
pub struct VendorRegistry;

fn factories() -> &'static RwLock<HashMap<CameraVendor, HandlerFactory>> {
    static FACTORIES: OnceLock<RwLock<HashMap<CameraVendor, HandlerFactory>>> = OnceLock::new();
    FACTORIES.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Canon EOS SetRemoteMode (CanonCodes.Op.setRemoteMode).
const CANON_SET_REMOTE_MODE: u16 = 0x9114;
/// Sony SDIOConnect (SonyCodes.Op.sdioConnect).
const SONY_SDIO_CONNECT: u16 = 0x9201;

impl VendorRegistry {
    pub fn register(vendor: CameraVendor, factory: HandlerFactory) {
        factories()
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .insert(vendor, factory);
    }

    pub fn make_handler(
        engine: Arc<PtpEngine>,
        info: PtpDeviceInfo,
        transport: TransportKind,
    ) -> Arc<dyn VendorHandler> {
        let vendor = detect_vendor(&info);
        let factory = factories()
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .get(&vendor)
            .cloned();
        // Brands without a dedicated handler (Hasselblad, Sigma, Pentax,
        // Samsung…) get the generic one: capture when the body offers
        // InitiateCapture, import otherwise. Wireless control is limited to
        // the brands whose protocols we ship.
        if transport == TransportKind::PtpIp && !vendor.supports_wireless_control() {
            return Arc::new(GenericPtpHandler::new(engine, info, None));
        }
        // A body whose vendor control mode is off (or a compact without it)
        // still imports, with a hint, instead of refusing to connect.
        if let Some(hint) = Self::vendor_mode_hint(vendor, &info) {
            return Arc::new(GenericPtpHandler::new(engine, info, Some(hint)));
        }
        match factory {
            Some(f) => f(engine, info),
            None => Arc::new(GenericPtpHandler::new(engine, info, None)),
        }
    }

    /// None when the vendor's control gate is available.
    pub fn vendor_mode_hint(vendor: CameraVendor, info: &PtpDeviceInfo) -> Option<String> {
        match vendor {
            CameraVendor::Canon if !info.supports_op_raw(CANON_SET_REMOTE_MODE) => Some(
                "This Canon offers import only over this connection. Photos you take arrive automatically."
                    .into(),
            ),
            CameraVendor::Sony if !info.supports_op_raw(SONY_SDIO_CONNECT) => Some(
                "Importing only. For remote control set USB Connection to PC Remote on the camera and reconnect."
                    .into(),
            ),
            _ => None,
        }
    }

    pub fn registered() -> Vec<CameraVendor> {
        factories()
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .keys()
            .copied()
            .collect()
    }
}
