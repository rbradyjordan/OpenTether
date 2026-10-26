//! Requests, responses, events and the error type shared by every transport.

use std::fmt;
use std::time::Duration;

use chrono::{DateTime, Utc};
use thiserror::Error;

use super::byte_buffer::ReadError;
use super::codes::{DataType, EventCode, OperationCode, ResponseCode};

/// A PTP operation request: up to five u32 parameters plus an optional
/// host-to-camera data phase.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtpRequest {
    pub code: OperationCode,
    pub parameters: Vec<u32>,
    pub data_out: Option<Vec<u8>>,
    pub expects_large_data: bool,
    pub timeout: Duration,
    /// Retry DeviceBusy with backoff (commands). Polls like live-view frames
    /// turn it off: there, busy just means "nothing new yet".
    pub retries_busy: bool,
}

impl PtpRequest {
    /// Defaults: no data out, 10 s timeout, DeviceBusy retried.
    /// Parameters past the fifth are dropped (PTP allows five).
    pub fn new(code: OperationCode, parameters: impl Into<Vec<u32>>) -> Self {
        let mut parameters = parameters.into();
        debug_assert!(parameters.len() <= 5, "PTP allows at most five parameters");
        parameters.truncate(5);
        Self {
            code,
            parameters,
            data_out: None,
            expects_large_data: false,
            timeout: Duration::from_secs(10),
            retries_busy: true,
        }
    }

    pub fn with_data_out(mut self, data: impl Into<Vec<u8>>) -> Self {
        self.data_out = Some(data.into());
        self
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn expecting_large_data(mut self, large: bool) -> Self {
        self.expects_large_data = large;
        self
    }

    pub fn retrying_busy(mut self, retries: bool) -> Self {
        self.retries_busy = retries;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtpResponse {
    pub code: ResponseCode,
    pub parameters: Vec<u32>,
    pub data_in: Vec<u8>,
    pub transaction_id: u32,
}

impl PtpResponse {
    pub fn new(code: ResponseCode) -> Self {
        Self {
            code,
            parameters: Vec::new(),
            data_in: Vec::new(),
            transaction_id: 0,
        }
    }

    pub fn is_ok(&self) -> bool {
        self.code.is_ok()
    }

    /// The response itself when OK, else `PtpError::Response` for `op`.
    pub fn checked(self, op: OperationCode) -> Result<Self, PtpError> {
        if self.is_ok() {
            Ok(self)
        } else {
            Err(PtpError::Response {
                op,
                code: self.code,
                parameters: self.parameters,
            })
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtpEvent {
    pub code: EventCode,
    pub parameters: Vec<u32>,
    pub transaction_id: u32,
    pub received_at: DateTime<Utc>,
}

impl PtpEvent {
    pub fn new(code: EventCode, parameters: impl Into<Vec<u32>>) -> Self {
        Self {
            code,
            parameters: parameters.into(),
            transaction_id: 0,
            received_at: Utc::now(),
        }
    }

    pub fn with_transaction_id(mut self, tid: u32) -> Self {
        self.transaction_id = tid;
        self
    }
}

impl fmt::Display for PtpEvent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let params: Vec<String> = self
            .parameters
            .iter()
            .map(|p| format!("0x{p:08x}"))
            .collect();
        write!(f, "{}({})", self.code, params.join(", "))
    }
}

/// Everything the engine, transports and handlers can fail with.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum PtpError {
    #[error("{op} failed: {code}{}", if parameters.is_empty() { String::new() } else { format!(" {parameters:?}") })]
    Response {
        op: OperationCode,
        code: ResponseCode,
        parameters: Vec<u32>,
    },
    #[error("The camera connection closed.")]
    TransportClosed,
    #[error("{op} timed out.")]
    Timeout { op: OperationCode },
    #[error("Malformed PTP data: {0}")]
    Malformed(String),
    #[error("Unsupported PTP data type {0}")]
    UnsupportedDataType(DataType),
    #[error("No PTP session is open.")]
    SessionNotOpen,
    #[error("Not connected to a camera.")]
    NotConnected,
    /// A vendor or camera-side refusal, worded for the user.
    #[error("{0}")]
    VendorGate(String),
    #[error("{0}")]
    Unsupported(String),
    #[error("Cancelled.")]
    Cancelled,
    /// Rust addition: Swift threw `ByteBuffer.ReadError` untyped.
    #[error("Malformed PTP data: {0}")]
    Read(#[from] ReadError),
    /// Rust addition: Swift threw `ChannelError` untyped (PTP/IP sockets).
    #[error("{0}")]
    Channel(#[from] crate::ptpip::ChannelError),
    /// Rust addition: Swift threw `URLError` untyped (HTTP cameras).
    #[error("{0}")]
    Http(String),
    /// Rust addition: Swift threw `PTPIPPacket.DecodeError` untyped.
    #[error("Malformed PTP/IP packet: {0}")]
    Decode(#[from] crate::ptpip::DecodeError),
}

impl PtpError {
    /// The camera's response code when this is a `Response` error.
    pub fn response_code(&self) -> Option<ResponseCode> {
        match self {
            Self::Response { code, .. } => Some(*code),
            _ => None,
        }
    }
}

pub type PtpResult<T> = Result<T, PtpError>;
