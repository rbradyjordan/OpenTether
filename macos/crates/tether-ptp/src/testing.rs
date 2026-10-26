//! Test support shared by this crate's tests and the vendor-handler tests:
//! a scripted fake camera transport and canned payload helpers. Not used by
//! production code.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use tether_types::TransportKind;

use crate::ptp::transport::lock;
use crate::ptp::{
    DevicePropCode, EventCode, EventStream, ObjectFormat, OperationCode, PtpDeviceInfo, PtpError,
    PtpEvent, PtpRequest, PtpResponse, PtpResult, PtpTransport, ResponseCode,
};

/// Answers one request.
pub type Script = Arc<dyn Fn(&PtpRequest) -> PtpResponse + Send + Sync>;

/// A fake camera for unit tests: answers each operation code from a script
/// (closure or canned response) and lets tests push events.
pub struct ScriptedTransport {
    kind: TransportKind,
    is_open: AtomicBool,
    handlers: Mutex<HashMap<OperationCode, Script>>,
    fallback: Mutex<Script>,
    requests: Mutex<Vec<PtpRequest>>,
    events: EventStream,
    /// When set, `open` fails with this error.
    pub open_error: Mutex<Option<PtpError>>,
}

impl ScriptedTransport {
    pub fn new(kind: TransportKind, device_info: PtpDeviceInfo) -> Arc<Self> {
        let t = Arc::new(Self {
            kind,
            is_open: AtomicBool::new(false),
            handlers: Mutex::new(HashMap::new()),
            fallback: Mutex::new(Arc::new(|_| {
                PtpResponse::new(ResponseCode::OPERATION_NOT_SUPPORTED)
            })),
            requests: Mutex::new(Vec::new()),
            events: EventStream::default(),
            open_error: Mutex::new(None),
        });
        let encoded = device_info.encoded();
        t.on(OperationCode::GET_DEVICE_INFO, move |_| ok(encoded.clone()));
        t.on(OperationCode::OPEN_SESSION, |_| ok(Vec::new()));
        t.on(OperationCode::CLOSE_SESSION, |_| ok(Vec::new()));
        t
    }

    /// USB transport answering `generic_info()`.
    pub fn generic() -> Arc<Self> {
        Self::new(TransportKind::Usb, generic_info())
    }

    pub fn on(
        &self,
        code: OperationCode,
        script: impl Fn(&PtpRequest) -> PtpResponse + Send + Sync + 'static,
    ) {
        lock(&self.handlers).insert(code, Arc::new(script));
    }

    pub fn on_any(&self, script: impl Fn(&PtpRequest) -> PtpResponse + Send + Sync + 'static) {
        *lock(&self.fallback) = Arc::new(script);
    }

    /// Every unscripted operation answers OK.
    pub fn ok_all(&self) {
        self.on_any(|_| ok(Vec::new()));
    }

    pub fn push(&self, event: PtpEvent) {
        self.events.push(event);
    }

    pub fn requests(&self) -> Vec<PtpRequest> {
        lock(&self.requests).clone()
    }

    pub fn requests_for(&self, code: OperationCode) -> Vec<PtpRequest> {
        lock(&self.requests)
            .iter()
            .filter(|r| r.code == code)
            .cloned()
            .collect()
    }
}

#[async_trait]
impl PtpTransport for ScriptedTransport {
    fn kind(&self) -> TransportKind {
        self.kind
    }

    fn is_open(&self) -> bool {
        self.is_open.load(Ordering::SeqCst)
    }

    async fn open(&self) -> PtpResult<()> {
        if let Some(e) = lock(&self.open_error).clone() {
            return Err(e);
        }
        self.is_open.store(true, Ordering::SeqCst);
        Ok(())
    }

    async fn close(&self) {
        self.is_open.store(false, Ordering::SeqCst);
    }

    async fn execute(&self, request: PtpRequest) -> PtpResult<PtpResponse> {
        if !self.is_open() {
            return Err(PtpError::NotConnected);
        }
        let (script, count) = {
            let mut reqs = lock(&self.requests);
            reqs.push(request.clone());
            let h = lock(&self.handlers).get(&request.code).cloned();
            (
                h.unwrap_or_else(|| lock(&self.fallback).clone()),
                reqs.len(),
            )
        };
        let mut r = script(&request);
        r.transaction_id = count as u32;
        Ok(r)
    }

    fn events(&self) -> EventStream {
        self.events.clone()
    }
}

/// OK with a data-in payload.
pub fn ok(data: Vec<u8>) -> PtpResponse {
    PtpResponse {
        code: ResponseCode::OK,
        parameters: Vec::new(),
        data_in: data,
        transaction_id: 0,
    }
}

/// OK with response parameters.
pub fn ok_params(params: Vec<u32>) -> PtpResponse {
    PtpResponse {
        parameters: params,
        ..ok(Vec::new())
    }
}

/// A failure response.
pub fn fail(code: ResponseCode) -> PtpResponse {
    PtpResponse::new(code)
}

/// The generic test body: "Generic Camera Co." "PTP-1", MTP vendor extension.
pub fn generic_info() -> PtpDeviceInfo {
    use OperationCode as O;
    PtpDeviceInfo {
        vendor_extension_id: 6,
        operations_supported: vec![
            O::GET_DEVICE_INFO,
            O::OPEN_SESSION,
            O::CLOSE_SESSION,
            O::GET_STORAGE_IDS,
            O::GET_STORAGE_INFO,
            O::GET_OBJECT_HANDLES,
            O::GET_OBJECT_INFO,
            O::GET_OBJECT,
            O::GET_PARTIAL_OBJECT,
            O::GET_THUMB,
            O::GET_DEVICE_PROP_DESC,
            O::GET_DEVICE_PROP_VALUE,
            O::SET_DEVICE_PROP_VALUE,
            O::INITIATE_CAPTURE,
        ],
        events_supported: vec![
            EventCode::OBJECT_ADDED,
            EventCode::DEVICE_PROP_CHANGED,
            EventCode::CAPTURE_COMPLETE,
        ],
        device_properties_supported: vec![
            DevicePropCode::F_NUMBER,
            DevicePropCode::EXPOSURE_TIME,
            DevicePropCode::EXPOSURE_INDEX,
            DevicePropCode::WHITE_BALANCE,
            DevicePropCode::BATTERY_LEVEL,
        ],
        capture_formats: vec![ObjectFormat::EXIF_JPEG],
        image_formats: vec![ObjectFormat::EXIF_JPEG],
        manufacturer: "Generic Camera Co.".into(),
        model: "PTP-1".into(),
        device_version: "1.0".into(),
        serial_number: "SN0001".into(),
        ..Default::default()
    }
}

/// A JPEG-shaped payload of `size` bytes (SOI … EOI).
pub fn fake_jpeg(size: usize) -> Vec<u8> {
    let mut d = vec![0xFF, 0xD8, 0xFF, 0xE0];
    d.extend(std::iter::repeat_n(0x11, size.saturating_sub(6)));
    d.extend([0xFF, 0xD9]);
    d
}
