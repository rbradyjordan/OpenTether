//! Leica SL / Q / M (wired only): LE session gate, ReleaseStage capture,
//! standard properties, object-handle diff for new files.
//! Ported from `LeicaHandler.swift`. Constants follow libgphoto2
//! `PTP_OC_LEICA_*`; all VERIFY.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use tether_types::{CameraCapabilities, CameraVendor, CaptureDestination};

use super::run;
use crate::device::{
    vendor_props, CameraEvent, GenericPtpHandler, NewObject, ObjectHandleDiffer,
    PropertyDescriptor, TetherProperty, VendorHandler,
};
use crate::ptp::{
    EventCode, OperationCode, ProgressFn, PtpDeviceInfo, PtpEngine, PtpError, PtpEvent,
    PtpObjectInfo, PtpRequest, PtpResult, PtpValue,
};

/// Leica operation codes.
pub mod op {
    use crate::ptp::OperationCode as O;
    /// VERIFY: libgphoto2 PTP_OC_LEICA_SetCameraSettings.
    pub const SET_CAMERA_SETTINGS: O = O(0x9001);
    /// VERIFY: libgphoto2 PTP_OC_LEICA_GetCameraSettings.
    pub const GET_CAMERA_SETTINGS: O = O(0x9002);
    /// VERIFY: libgphoto2 PTP_OC_LEICA_GetLensParameter.
    pub const GET_LENS_PARAMETER: O = O(0x9003);
    /// VERIFY: libgphoto2 PTP_OC_LEICA_LEReleaseStage.
    pub const RELEASE_STAGE: O = O(0x9004);
    /// VERIFY: libgphoto2 PTP_OC_LEICA_LEOpenSession.
    pub const OPEN_LE_SESSION: O = O(0x9005);
    /// VERIFY: libgphoto2 PTP_OC_LEICA_LECloseSession.
    pub const CLOSE_LE_SESSION: O = O(0x9006);
    /// VERIFY
    pub const REQUEST_OBJECT_ERASE: O = O(0x9007);
    /// VERIFY
    pub const REQUEST_OBJECT_SAVE_AS: O = O(0x9008);
    /// VERIFY
    pub const REQUEST_OBJECT_DOWNLOAD: O = O(0x9009);
}

/// ReleaseStage parameters. VERIFY: 1 = half press, 2 = full press, 0 = release.
pub const HALF_PRESS: u32 = 1;
pub const FULL_PRESS: u32 = 2;
pub const RELEASE_ALL: u32 = 0;
/// LEOpenSession parameter. VERIFY: libgphoto2 passes the session id (1).
pub const LE_SESSION: u32 = 1;

/// Leica SL / Q / M (wired only): LE session gate, ReleaseStage capture,
/// standard properties, object-handle diff for new files.
pub struct LeicaHandler {
    pub engine: Arc<PtpEngine>,
    pub info: PtpDeviceInfo,
    capabilities: CameraCapabilities,
    generic: GenericPtpHandler,
    pub differ: ObjectHandleDiffer,
    le_session_open: AtomicBool,
}

impl LeicaHandler {
    pub fn new(engine: Arc<PtpEngine>, info: PtpDeviceInfo) -> Self {
        use CameraCapabilities as C;
        let generic = GenericPtpHandler::new(engine.clone(), info.clone(), None);
        let mut caps = C::empty();
        if info.supports_op(op::RELEASE_STAGE) || info.supports_op(OperationCode::INITIATE_CAPTURE)
        {
            caps |= C::REMOTE_CAPTURE | C::CARD_CAPTURE;
        }
        if info.supports_op(op::RELEASE_STAGE) {
            caps |= C::AUTOFOCUS;
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
            le_session_open: AtomicBool::new(false),
        }
    }
}

#[async_trait]
impl VendorHandler for LeicaHandler {
    fn vendor(&self) -> CameraVendor {
        CameraVendor::Leica
    }

    fn capabilities(&self) -> CameraCapabilities {
        self.capabilities
    }

    fn event_poll_interval(&self) -> Duration {
        Duration::from_millis(500)
    }

    async fn prepare(&self) -> PtpResult<()> {
        if self.info.supports_op(op::OPEN_LE_SESSION) {
            run(
                &self.engine,
                op::OPEN_LE_SESSION,
                &[LE_SESSION],
                None,
                false,
            )
            .await?;
            self.le_session_open.store(true, Ordering::SeqCst);
        }
        self.differ.seed(&self.engine).await;
        Ok(())
    }

    async fn teardown(&self) {
        if self.le_session_open.swap(false, Ordering::SeqCst)
            && self.info.supports_op(op::CLOSE_LE_SESSION)
        {
            let _ = self
                .engine
                .execute(PtpRequest::new(op::CLOSE_LE_SESSION, [LE_SESSION]))
                .await;
        }
    }

    async fn set_capture_destination(&self, destination: CaptureDestination) -> PtpResult<()> {
        if destination != CaptureDestination::Card {
            return Err(PtpError::Unsupported(
                "Leica bodies write to the card; the file is copied over afterwards.".into(),
            ));
        }
        Ok(())
    }

    async fn capture(&self, autofocus: bool) -> PtpResult<()> {
        if self.info.supports_op(op::RELEASE_STAGE) {
            if autofocus {
                run(
                    &self.engine,
                    op::RELEASE_STAGE,
                    &[HALF_PRESS],
                    Some(15.0),
                    false,
                )
                .await?;
            }
            run(
                &self.engine,
                op::RELEASE_STAGE,
                &[FULL_PRESS],
                Some(15.0),
                false,
            )
            .await?;
            run(&self.engine, op::RELEASE_STAGE, &[RELEASE_ALL], None, false).await?;
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
        if e.code == EventCode::OBJECT_ADDED {
            if let Some(&h) = e.parameters.first() {
                self.differ.mark_known(h);
            }
        }
        self.generic.translate(e).await
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
}
