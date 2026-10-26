//! Duplex byte channels for PTP/IP: the trait the transport talks to and a
//! tokio TCP implementation.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::TcpStream;
use tokio::sync::{watch, Mutex as AsyncMutex};

use crate::ptp::{PtpError, PtpResult};

/// A duplex byte channel. The PTP/IP transport opens two: command and event.
#[async_trait]
pub trait PtpIpChannel: Send + Sync {
    async fn send(&self, data: &[u8]) -> PtpResult<()>;
    /// Next chunk of bytes; `PtpError::TransportClosed` at EOF or after `close`.
    async fn receive(&self) -> PtpResult<Vec<u8>>;
    /// Wakes pending receives with `TransportClosed`. Never blocks.
    fn close(&self);
}

/// Opens channels. Fujifilm bodies dial back to us, so their connector can
/// accept instead of connect; everything else uses `TcpConnector`.
#[async_trait]
pub trait PtpIpConnector: Send + Sync {
    async fn connect(
        &self,
        host: &str,
        port: u16,
        timeout: Duration,
    ) -> PtpResult<Arc<dyn PtpIpChannel>>;
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ChannelError {
    #[error("Could not resolve {0}.")]
    ResolveFailed(String),
    #[error("Could not connect to {0} (errno {1}).")]
    ConnectFailed(String, i32),
    #[error("Connection timed out.")]
    Timeout,
    #[error("Write failed (errno {0}).")]
    WriteFailed(i32),
    #[error("Connection closed.")]
    Closed,
}

/// A connected TCP stream as a PTP/IP channel. Reads and writes are
/// independent (split halves); `close` cancels a pending read at once.
pub struct TcpChannel {
    reader: AsyncMutex<OwnedReadHalf>,
    writer: AsyncMutex<OwnedWriteHalf>,
    closed: AtomicBool,
    eof: AtomicBool,
    close_tx: watch::Sender<bool>,
}

impl TcpChannel {
    /// Read chunk size; matches the iOS socket reader.
    const READ_CHUNK: usize = 256 * 1024;

    pub fn new(stream: TcpStream) -> Self {
        let _ = stream.set_nodelay(true);
        let _ = socket2::SockRef::from(&stream).set_keepalive(true);
        let (r, w) = stream.into_split();
        let (close_tx, _) = watch::channel(false);
        Self {
            reader: AsyncMutex::new(r),
            writer: AsyncMutex::new(w),
            closed: AtomicBool::new(false),
            eof: AtomicBool::new(false),
            close_tx,
        }
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl PtpIpChannel for TcpChannel {
    async fn send(&self, data: &[u8]) -> PtpResult<()> {
        if self.is_closed() {
            return Err(PtpError::TransportClosed);
        }
        let mut w = self.writer.lock().await;
        w.write_all(data).await.map_err(|e| {
            PtpError::Channel(ChannelError::WriteFailed(e.raw_os_error().unwrap_or(0)))
        })
    }

    async fn receive(&self) -> PtpResult<Vec<u8>> {
        let mut closed_rx = self.close_tx.subscribe();
        if self.is_closed() || self.eof.load(Ordering::SeqCst) {
            return Err(PtpError::TransportClosed);
        }
        let mut r = self.reader.lock().await;
        let mut buf = vec![0u8; Self::READ_CHUNK];
        tokio::select! {
            res = r.read(&mut buf) => match res {
                Ok(0) | Err(_) => {
                    self.eof.store(true, Ordering::SeqCst);
                    Err(PtpError::TransportClosed)
                }
                Ok(n) => {
                    buf.truncate(n);
                    Ok(buf)
                }
            },
            _ = closed_rx.wait_for(|c| *c) => Err(PtpError::TransportClosed),
        }
    }

    fn close(&self) {
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        let _ = self.close_tx.send(true);
        // Half-close the write side when nobody is mid-write so the camera
        // sees FIN now; the socket itself closes when the last handle drops.
        if let Ok(w) = self.writer.try_lock() {
            let _ = socket2::SockRef::from(w.as_ref()).shutdown(std::net::Shutdown::Both);
        }
    }
}

impl Drop for TcpChannel {
    fn drop(&mut self) {
        self.close();
    }
}

/// Resolves and connects over TCP with a timeout.
#[derive(Debug, Clone, Copy, Default)]
pub struct TcpConnector;

#[async_trait]
impl PtpIpConnector for TcpConnector {
    async fn connect(
        &self,
        host: &str,
        port: u16,
        timeout: Duration,
    ) -> PtpResult<Arc<dyn PtpIpChannel>> {
        let addrs: Vec<_> = tokio::net::lookup_host((host, port))
            .await
            .map_err(|_| ChannelError::ResolveFailed(host.to_string()))?
            .collect();
        if addrs.is_empty() {
            return Err(ChannelError::ResolveFailed(host.to_string()).into());
        }
        let mut last_err = 0;
        for addr in addrs {
            match tokio::time::timeout(timeout, TcpStream::connect(addr)).await {
                Err(_) => return Err(ChannelError::Timeout.into()),
                Ok(Ok(stream)) => return Ok(Arc::new(TcpChannel::new(stream))),
                Ok(Err(e)) => last_err = e.raw_os_error().unwrap_or(0),
            }
        }
        Err(ChannelError::ConnectFailed(host.to_string(), last_err).into())
    }
}
