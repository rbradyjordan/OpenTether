//! Olympus / OM System (wired only): control-mode gate, OMD capture,
//! standard properties, object-handle diff for new files.
//! Ported from `OlympusHandler.swift`.
//!
//! Constants follow libgphoto2 `PTP_OC_OLYMPUS_OMD_*`, `PTP_DPC_OLYMPUS_*`.
//! Everything here is VERIFY until a body confirms it.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tether_types::{
    jpeg_payload, CameraCapabilities, CameraVendor, CaptureDestination, LiveViewFrame,
    LiveViewQuality,
};

use super::{live_frame, no_live_view, run};
use crate::device::{
    vendor_props, CameraEvent, GenericPtpHandler, NewObject, ObjectHandleDiffer,
    PropertyDescriptor, TetherProperty, VendorHandler,
};
use crate::ptp::transport::lock;
use crate::ptp::{
    DevicePropCode, EventCode, OperationCode, ProgressFn, PtpDeviceInfo, PtpEngine, PtpError,
    PtpEvent, PtpObjectInfo, PtpRequest, PtpResult, PtpValue,
};

/// Olympus operation codes.
pub mod op {
    use crate::ptp::OperationCode as O;
    /// VERIFY: libgphoto2 PTP_OC_OLYMPUS_OMD_Capture.
    pub const CAPTURE: O = O(0x9481);
    /// VERIFY
    pub const GET_INCREASE_CAPTURE: O = O(0x9482);
    /// VERIFY: libgphoto2 PTP_OC_OLYMPUS_GetLiveViewImage.
    pub const GET_LIVE_VIEW_IMAGE: O = O(0x9484);
    /// VERIFY: libgphoto2 PTP_OC_OLYMPUS_OMD_MFDrive.
    pub const MF_DRIVE: O = O(0x9487);
    /// VERIFY: libgphoto2 PTP_OC_OLYMPUS_OMD_SetProperties.
    pub const SET_PROPERTIES: O = O(0x9489);
}

/// Olympus device property codes.
pub mod prop {
    use crate::ptp::DevicePropCode as P;
    /// VERIFY: libgphoto2 PTP_DPC_OLYMPUS_Aperture (not used for display).
    pub const APERTURE: P = P(0xD002);
    /// VERIFY: 1 = remote control.
    pub const CAMERA_CONTROL_MODE: P = P(0xD052);
    /// VERIFY: libgphoto2 PTP_DPC_OLYMPUS_LiveViewModeOM.
    pub const LIVE_VIEW_MODE: P = P(0xD06D);
    pub const CONTROL_MODE_REMOTE: u8 = 1;
}

/// Olympus event codes.
pub mod event {
    use crate::ptp::EventCode as E;
    /// VERIFY: libgphoto2 PTP_EC_Olympus_PropertyChanged.
    pub const PROPERTY_CHANGED: E = E(0xC008);
    /// VERIFY
    pub const CAPTURE_COMPLETE: E = E(0xC003);
}

/// Capture parameters. VERIFY: libgphoto2 sends 0x3 (press) then 0x6 (release).
pub const CAPTURE_PRESS: u32 = 0x3;
pub const CAPTURE_RELEASE: u32 = 0x6;
/// Live view image parameter. VERIFY: libgphoto2 uses 0x00000001.
pub const LIVE_VIEW_PARAM: u32 = 1;

struct LiveState {
    on: bool,
    frame_sequence: u64,
}

/// Olympus / OM System (wired only): control-mode gate, OMD capture,
/// standard properties, object-handle diff for new files.
pub struct OlympusHandler {
    pub engine: Arc<PtpEngine>,
    pub info: PtpDeviceInfo,
    capabilities: CameraCapabilities,
    generic: GenericPtpHandler,
    pub differ: ObjectHandleDiffer,
    live: Mutex<LiveState>,
}

impl OlympusHandler {
    pub fn new(engine: Arc<PtpEngine>, info: PtpDeviceInfo) -> Self {
        use CameraCapabilities as C;
        let generic = GenericPtpHandler::new(engine.clone(), info.clone(), None);
        let mut caps = C::empty();
        if info.supports_op(op::CAPTURE) || info.supports_op(OperationCode::INITIATE_CAPTURE) {
            caps |= C::REMOTE_CAPTURE | C::CARD_CAPTURE;
        }
        if info.supports_op(op::CAPTURE) {
            caps |= C::AUTOFOCUS;
        }
        if info.supports_op(op::GET_LIVE_VIEW_IMAGE) {
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
}

#[async_trait]
impl VendorHandler for OlympusHandler {
    fn vendor(&self) -> CameraVendor {
        CameraVendor::Olympus
    }

    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities
    }

    fn event_poll_interval(&self) -> Duration {
        Duration::from_millis(500)
    }

    async fn prepare(&self) -> PtpResult<()> {
        if self.info.supports_prop(prop::CAMERA_CONTROL_MODE) {
            self.engine
                .set_device_prop_value(
                    prop::CAMERA_CONTROL_MODE,
                    &PtpValue::UInt8(prop::CONTROL_MODE_REMOTE),
                )
                .await?;
        }
        self.differ.seed(&self.engine).await;
        Ok(())
    }

    async fn teardown(&self) {
        self.stop_live_view().await;
        if self.info.supports_prop(prop::CAMERA_CONTROL_MODE) {
            let _ = self
                .engine
                .set_device_prop_value(prop::CAMERA_CONTROL_MODE, &PtpValue::UInt8(0))
                .await;
        }
    }

    async fn set_capture_destination(&self, destination: CaptureDestination) -> PtpResult<()> {
        if destination != CaptureDestination::Card {
            return Err(PtpError::Unsupported(
                "Olympus bodies write to the card; the file is copied over afterwards.".into(),
            ));
        }
        Ok(())
    }

    async fn capture(&self, _autofocus: bool) -> PtpResult<()> {
        if self.info.supports_op(op::CAPTURE) {
            run(
                &self.engine,
                op::CAPTURE,
                &[CAPTURE_PRESS],
                Some(30.0),
                false,
            )
            .await?;
            run(
                &self.engine,
                op::CAPTURE,
                &[CAPTURE_RELEASE],
                Some(30.0),
                false,
            )
            .await?;
            Ok(())
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
            event::PROPERTY_CHANGED => {
                Some(CameraEvent::PropertyChanged(e.parameters.first().and_then(
                    |&c| GenericPtpHandler::standard_property(DevicePropCode(c as u16)),
                )))
            }
            event::CAPTURE_COMPLETE => Some(CameraEvent::CaptureComplete),
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
        let mut out = self.generic.read_properties(properties).await?;
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
        self.generic.write_property(property, raw).await
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
        if self.info.supports_prop(prop::LIVE_VIEW_MODE) {
            let _ = self
                .engine
                .set_device_prop_value(prop::LIVE_VIEW_MODE, &PtpValue::UInt32(1))
                .await;
        }
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
        if self.info.supports_prop(prop::LIVE_VIEW_MODE) {
            let _ = self
                .engine
                .set_device_prop_value(prop::LIVE_VIEW_MODE, &PtpValue::UInt32(0))
                .await;
        }
    }

    async fn next_live_view_frame(&self) -> PtpResult<Option<LiveViewFrame>> {
        if !lock(&self.live).on {
            return Ok(None);
        }
        let req = PtpRequest::new(op::GET_LIVE_VIEW_IMAGE, [LIVE_VIEW_PARAM])
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
