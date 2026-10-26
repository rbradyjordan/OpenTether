//! The transport-agnostic PTP engine and its transaction log.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use tether_types::TransportKind;

use super::byte_buffer::ByteBuffer;
use super::codes::{DataType, DevicePropCode, ObjectFormat, OperationCode, ResponseCode};
use super::data_sets::{PtpDeviceInfo, PtpDevicePropDesc, PtpObjectInfo, PtpStorageInfo};
use super::transaction::{PtpError, PtpRequest, PtpResponse, PtpResult};
use super::transport::{lock, EventStream, PtpTransport};
use super::value::PtpValue;

/// Download progress: (bytes so far, total when known).
pub type ProgressFn = Arc<dyn Fn(usize, Option<usize>) + Send + Sync>;

/// The transport-agnostic PTP engine. Owns the session and offers typed
/// helpers for the generic operations every vendor shares. Transactions are
/// serialised by the transport (PTP permits one outstanding operation per
/// session), so the engine can be shared (`Arc<PtpEngine>`) between the
/// capture loop and the vendor handler.
///
/// Vendor handlers call `execute`/`run` for their own opcodes; the capture
/// loop calls the typed helpers. Nothing here touches a database or the UI.
pub struct PtpEngine {
    transport: Arc<dyn PtpTransport>,
    state: Mutex<EngineState>,
}

struct EngineState {
    session_id: u32,
    device_info: Option<PtpDeviceInfo>,
    is_session_open: bool,
    partial_chunk_size: u32,
    log: Option<Arc<PtpLog>>,
    retry_busy_attempts: u32,
}

impl PtpEngine {
    pub fn new(transport: Arc<dyn PtpTransport>) -> Self {
        Self::with_log(transport, None)
    }

    pub fn with_log(transport: Arc<dyn PtpTransport>, log: Option<Arc<PtpLog>>) -> Self {
        Self {
            transport,
            state: Mutex::new(EngineState {
                session_id: 0,
                device_info: None,
                is_session_open: false,
                // 1 MiB keeps USB and Wi-Fi progress callbacks responsive
                // without flooding the camera.
                partial_chunk_size: 1 << 20,
                log,
                retry_busy_attempts: 6,
            }),
        }
    }

    pub fn transport(&self) -> &Arc<dyn PtpTransport> {
        &self.transport
    }
    pub fn kind(&self) -> TransportKind {
        self.transport.kind()
    }
    pub fn events(&self) -> EventStream {
        self.transport.events()
    }
    pub fn session_id(&self) -> u32 {
        lock(&self.state).session_id
    }
    pub fn device_info(&self) -> Option<PtpDeviceInfo> {
        lock(&self.state).device_info.clone()
    }
    pub fn is_session_open(&self) -> bool {
        lock(&self.state).is_session_open
    }
    /// Chunk size for GetPartialObject downloads.
    pub fn partial_chunk_size(&self) -> u32 {
        lock(&self.state).partial_chunk_size
    }
    pub fn set_partial_chunk_size(&self, n: u32) {
        lock(&self.state).partial_chunk_size = n.max(1);
    }
    pub fn set_log(&self, log: Option<Arc<PtpLog>>) {
        lock(&self.state).log = log;
    }
    /// How many times `execute` retries DeviceBusy (default 6). Rust
    /// addition so tests of busy paths don't sit through the backoff.
    pub fn set_retry_busy_attempts(&self, n: u32) {
        lock(&self.state).retry_busy_attempts = n;
    }

    // MARK: Session

    /// Open the link and a PTP session, then read DeviceInfo.
    pub async fn connect(&self, session_id: u32) -> PtpResult<PtpDeviceInfo> {
        self.transport.open().await?;
        let info = self.get_device_info().await?;
        if info.supports_op(OperationCode::OPEN_SESSION) {
            self.open_session(session_id).await?;
        }
        Ok(info)
    }

    pub async fn open_session(&self, id: u32) -> PtpResult<()> {
        let r = self
            .execute(PtpRequest::new(OperationCode::OPEN_SESSION, [id]))
            .await?;
        match r.code {
            ResponseCode::OK | ResponseCode::SESSION_ALREADY_OPEN => {
                let mut s = lock(&self.state);
                s.session_id = id;
                s.is_session_open = true;
                Ok(())
            }
            code => Err(PtpError::Response {
                op: OperationCode::OPEN_SESSION,
                code,
                parameters: r.parameters,
            }),
        }
    }

    pub async fn close_session(&self) {
        if self.is_session_open() {
            let _ = self
                .execute(PtpRequest::new(OperationCode::CLOSE_SESSION, []))
                .await;
            lock(&self.state).is_session_open = false;
        }
    }

    pub async fn disconnect(&self) {
        self.close_session().await;
        self.transport.close().await;
    }

    // MARK: Raw transactions

    /// Execute a request, retrying `DeviceBusy` with backoff. Logs every
    /// transaction when a `PtpLog` is attached.
    pub async fn execute(&self, request: PtpRequest) -> PtpResult<PtpResponse> {
        let mut attempt = 0u32;
        loop {
            let started = Instant::now();
            let result = self.transport.execute(request.clone()).await;
            let (log, retry_limit) = {
                let s = lock(&self.state);
                (s.log.clone(), s.retry_busy_attempts)
            };
            let response = match result {
                Ok(r) => r,
                Err(e) => {
                    if let Some(log) = &log {
                        log.record(LogEntry::new(
                            request.clone(),
                            None,
                            Some(e.to_string()),
                            started.elapsed(),
                        ));
                    }
                    return Err(e);
                }
            };
            if let Some(log) = &log {
                log.record(LogEntry::new(
                    request.clone(),
                    Some(response.clone()),
                    None,
                    started.elapsed(),
                ));
            }
            if response.code == ResponseCode::DEVICE_BUSY
                && request.retries_busy
                && attempt < retry_limit
            {
                attempt += 1;
                tokio::time::sleep(Duration::from_millis(50 << attempt.min(5))).await;
                continue;
            }
            return Ok(response);
        }
    }

    /// Execute with the given options and require OK.
    pub async fn run_request(&self, request: PtpRequest) -> PtpResult<PtpResponse> {
        let code = request.code;
        self.execute(request).await?.checked(code)
    }

    /// Execute (10 s timeout, no data out) and require OK.
    pub async fn run(&self, code: OperationCode, parameters: &[u32]) -> PtpResult<PtpResponse> {
        self.run_request(PtpRequest::new(code, parameters)).await
    }

    // MARK: Typed generic operations

    pub async fn get_device_info(&self) -> PtpResult<PtpDeviceInfo> {
        let r = self.run(OperationCode::GET_DEVICE_INFO, &[]).await?;
        let info = PtpDeviceInfo::parse(&r.data_in)?;
        lock(&self.state).device_info = Some(info.clone());
        Ok(info)
    }

    pub async fn get_storage_ids(&self) -> PtpResult<Vec<u32>> {
        let r = self.run(OperationCode::GET_STORAGE_IDS, &[]).await?;
        Ok(ByteBuffer::from(r.data_in).read_u32_array()?)
    }

    pub async fn get_storage_info(&self, id: u32) -> PtpResult<PtpStorageInfo> {
        let r = self.run(OperationCode::GET_STORAGE_INFO, &[id]).await?;
        PtpStorageInfo::parse(&r.data_in)
    }

    /// All handles in `storage` (0xFFFFFFFF = every store), optionally filtered
    /// by format and parent (0xFFFFFFFF = root, 0 = everything).
    pub async fn get_object_handles(
        &self,
        storage: u32,
        format: Option<ObjectFormat>,
        parent: u32,
    ) -> PtpResult<Vec<u32>> {
        let mut params = vec![storage, u32::from(format.map_or(0, |f| f.0))];
        if parent != 0 {
            params.push(parent);
        }
        let r = self.run(OperationCode::GET_OBJECT_HANDLES, &params).await?;
        Ok(ByteBuffer::from(r.data_in).read_u32_array()?)
    }

    /// Every handle on every store.
    pub async fn get_all_object_handles(&self) -> PtpResult<Vec<u32>> {
        self.get_object_handles(0xFFFF_FFFF, None, 0).await
    }

    pub async fn get_object_info(&self, handle: u32) -> PtpResult<PtpObjectInfo> {
        let r = self.run(OperationCode::GET_OBJECT_INFO, &[handle]).await?;
        PtpObjectInfo::parse(&r.data_in)
    }

    pub async fn get_thumb(&self, handle: u32) -> PtpResult<Vec<u8>> {
        let req = PtpRequest::new(OperationCode::GET_THUMB, [handle])
            .expecting_large_data(true)
            .with_timeout(Duration::from_secs(30));
        Ok(self.run_request(req).await?.data_in)
    }

    /// Whole object in one transaction (default timeout 120 s).
    pub async fn get_object(&self, handle: u32, timeout: Option<Duration>) -> PtpResult<Vec<u8>> {
        let req = PtpRequest::new(OperationCode::GET_OBJECT, [handle])
            .expecting_large_data(true)
            .with_timeout(timeout.unwrap_or(Duration::from_secs(120)));
        Ok(self.run_request(req).await?.data_in)
    }

    /// Chunked download with progress. Uses GetPartialObject when supported,
    /// otherwise falls back to GetObject. Vendors with their own partial
    /// opcode (Canon GetPartialObjectEx) override through the handler.
    pub async fn download(
        &self,
        handle: u32,
        size: Option<u32>,
        progress: Option<ProgressFn>,
    ) -> PtpResult<Vec<u8>> {
        let supports_partial = self
            .device_info()
            .is_none_or(|i| i.supports_op(OperationCode::GET_PARTIAL_OBJECT));
        let total = match size {
            Some(t) if supports_partial && t > 0 => t,
            _ => {
                let d = self.get_object(handle, None).await?;
                if let Some(p) = &progress {
                    p(d.len(), Some(d.len()));
                }
                return Ok(d);
            }
        };
        let chunk = self.partial_chunk_size();
        let mut out = Vec::with_capacity(total as usize);
        let mut offset: u32 = 0;
        while offset < total {
            let want = chunk.min(total - offset);
            let req = PtpRequest::new(OperationCode::GET_PARTIAL_OBJECT, [handle, offset, want])
                .expecting_large_data(true)
                .with_timeout(Duration::from_secs(60));
            let r = self.run_request(req).await?;
            if r.data_in.is_empty() {
                return Err(PtpError::Malformed(format!(
                    "GetPartialObject returned no data at {offset}"
                )));
            }
            out.extend_from_slice(&r.data_in);
            // A short chunk just means we continue from where the camera stopped.
            offset = offset.saturating_add(u32::try_from(r.data_in.len()).unwrap_or(u32::MAX));
            if let Some(p) = &progress {
                p(out.len(), Some(total as usize));
            }
        }
        Ok(out)
    }

    pub async fn delete_object(&self, handle: u32) -> PtpResult<()> {
        self.run(OperationCode::DELETE_OBJECT, &[handle, 0])
            .await
            .map(|_| ())
    }

    pub async fn get_device_prop_desc(&self, code: DevicePropCode) -> PtpResult<PtpDevicePropDesc> {
        let r = self
            .run(OperationCode::GET_DEVICE_PROP_DESC, &[u32::from(code.0)])
            .await?;
        PtpDevicePropDesc::parse(&r.data_in)
    }

    pub async fn get_device_prop_value(
        &self,
        code: DevicePropCode,
        data_type: DataType,
    ) -> PtpResult<PtpValue> {
        let r = self
            .run(OperationCode::GET_DEVICE_PROP_VALUE, &[u32::from(code.0)])
            .await?;
        PtpValue::read(data_type, &mut ByteBuffer::from(r.data_in))
    }

    /// Vendor GetDevicePropValue for a code the standard table does not know.
    pub async fn get_raw_prop_value(&self, code: u16) -> PtpResult<Vec<u8>> {
        Ok(self
            .run(OperationCode::GET_DEVICE_PROP_VALUE, &[u32::from(code)])
            .await?
            .data_in)
    }

    pub async fn set_device_prop_value(
        &self,
        code: DevicePropCode,
        value: &PtpValue,
    ) -> PtpResult<()> {
        let req = PtpRequest::new(OperationCode::SET_DEVICE_PROP_VALUE, [u32::from(code.0)])
            .with_data_out(value.encoded());
        self.run_request(req).await.map(|_| ())
    }

    /// Generic capture (PTP 1.1 §10.4.14). Vendors with two-stage shutters
    /// do not use this.
    pub async fn initiate_capture(
        &self,
        storage: u32,
        format: Option<ObjectFormat>,
    ) -> PtpResult<()> {
        let req = PtpRequest::new(
            OperationCode::INITIATE_CAPTURE,
            [storage, u32::from(format.map_or(0, |f| f.0))],
        )
        .with_timeout(Duration::from_secs(30));
        self.run_request(req).await.map(|_| ())
    }

    pub async fn initiate_open_capture(&self, storage: u32) -> PtpResult<u32> {
        let req = PtpRequest::new(OperationCode::INITIATE_OPEN_CAPTURE, [storage, 0])
            .with_timeout(Duration::from_secs(30));
        Ok(self.run_request(req).await?.transaction_id)
    }

    pub async fn terminate_open_capture(&self, transaction_id: u32) -> PtpResult<()> {
        self.run(OperationCode::TERMINATE_OPEN_CAPTURE, &[transaction_id])
            .await
            .map(|_| ())
    }
}

/// One logged transaction.
#[derive(Debug, Clone)]
pub struct LogEntry {
    pub at: DateTime<Utc>,
    pub request: PtpRequest,
    pub response: Option<PtpResponse>,
    pub error: Option<String>,
    pub duration: Duration,
}

impl LogEntry {
    pub fn new(
        request: PtpRequest,
        response: Option<PtpResponse>,
        error: Option<String>,
        duration: Duration,
    ) -> Self {
        Self {
            at: Utc::now(),
            request,
            response,
            error,
            duration,
        }
    }

    /// `GetObject(0x00000077) out=2B → OK in=300000B 12ms`.
    pub fn line(&self) -> String {
        let params: Vec<String> = self
            .request
            .parameters
            .iter()
            .map(|p| format!("0x{p:08x}"))
            .collect();
        let out = self
            .request
            .data_out
            .as_ref()
            .map(|d| format!(" out={}B", d.len()))
            .unwrap_or_default();
        let result = if let Some(e) = &self.error {
            format!("ERR {e}")
        } else if let Some(r) = &self.response {
            if r.data_in.is_empty() {
                r.code.to_string()
            } else {
                format!("{} in={}B", r.code, r.data_in.len())
            }
        } else {
            "?".to_string()
        };
        format!(
            "{}({}){} → {} {:.0}ms",
            self.request.code,
            params.join(","),
            out,
            result,
            self.duration.as_secs_f64() * 1000.0
        )
    }
}

/// In-memory ring of recent transactions for the diagnostics screen.
pub struct PtpLog {
    entries: Mutex<VecDeque<LogEntry>>,
    pub capacity: usize,
}

impl PtpLog {
    pub fn new(capacity: usize) -> Self {
        Self {
            entries: Mutex::new(VecDeque::new()),
            capacity,
        }
    }

    pub fn record(&self, e: LogEntry) {
        let mut entries = lock(&self.entries);
        entries.push_back(e);
        while entries.len() > self.capacity {
            entries.pop_front();
        }
    }

    pub fn recent(&self) -> Vec<LogEntry> {
        lock(&self.entries).iter().cloned().collect()
    }

    pub fn clear(&self) {
        lock(&self.entries).clear();
    }
}

impl Default for PtpLog {
    fn default() -> Self {
        Self::new(500)
    }
}
