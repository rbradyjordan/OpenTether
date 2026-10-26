//! FTP server that cameras push to. One accept task; each connection runs as
//! its own task. Nothing here is durable: files land under `root_directory`
//! and the app indexes them from [`ReceivedFile`]s / `FileReceived` events.
//! Ported from `FTPServer.swift`.

use std::collections::HashMap;
use std::net::Ipv4Addr;
use std::ops::RangeInclusive;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tokio::sync::{broadcast, mpsc, watch};
use tokio::task::JoinHandle;

use super::session::Session;
use crate::{lock, net};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FtpServerConfig {
    /// 0 = ephemeral. Default 2121 (unprivileged; cameras let you type any port).
    pub port: u16,
    pub username: String,
    pub password: String,
    pub allow_anonymous: bool,
    pub root_directory: PathBuf,
    pub passive_port_range: RangeInclusive<u16>,
    /// Time without a command (or data) before a client is dropped.
    pub idle_timeout: Duration,
    /// How often idle clients are checked (tests lower it).
    pub heartbeat_interval: Duration,
}

impl FtpServerConfig {
    pub const DEFAULT_PORT: u16 = 2121;
    pub const DEFAULT_PASSIVE_RANGE: RangeInclusive<u16> = 40000..=40100;

    pub fn new(root_directory: impl Into<PathBuf>) -> Self {
        Self {
            port: Self::DEFAULT_PORT,
            username: "tether".into(),
            password: "tether".into(),
            allow_anonymous: false,
            root_directory: root_directory.into(),
            passive_port_range: Self::DEFAULT_PASSIVE_RANGE,
            idle_timeout: Duration::from_secs(300),
            heartbeat_interval: Duration::from_secs(5),
        }
    }
}

/// Everything the server reports, for logs and the UI.
#[derive(Debug, Clone, PartialEq)]
pub enum FtpServerEvent {
    Started {
        port: u16,
        addresses: Vec<String>,
    },
    ClientConnected(String),
    ClientDisconnected(String),
    LoginFailed(String),
    TransferStarted {
        path: String,
        from: String,
    },
    TransferProgress {
        path: String,
        bytes: u64,
    },
    FileReceived {
        path: PathBuf,
        bytes: u64,
        from: String,
        duration: Duration,
    },
    Rebound {
        addresses: Vec<String>,
    },
    Error(String),
    Stopped,
}

/// A completed upload, delivered once on the server's file channel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReceivedFile {
    /// On-disk location under the root directory.
    pub path: PathBuf,
    /// Path as the client named it ("/2026/DSC_0001.JPG").
    pub virtual_path: String,
    /// Bytes that crossed the wire in this transfer (the remainder when resumed).
    pub size: u64,
    /// The client's IP address.
    pub client: String,
    pub duration: Duration,
}

#[derive(Debug, thiserror::Error)]
pub enum FtpServerError {
    #[error("Could not create {path}: {source}")]
    RootDirectory {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("Could not listen on port {port}: {source}")]
    Bind {
        port: u16,
        #[source]
        source: std::io::Error,
    },
}

pub struct FtpServer {
    inner: Arc<ServerInner>,
}

pub(crate) struct ServerInner {
    pub(crate) config: FtpServerConfig,
    events: broadcast::Sender<FtpServerEvent>,
    files_tx: mpsc::UnboundedSender<ReceivedFile>,
    files_rx: Mutex<Option<mpsc::UnboundedReceiver<ReceivedFile>>>,
    state: Mutex<ServerState>,
    passive_cursor: Mutex<u16>,
    next_session: AtomicU64,
}

#[derive(Default)]
struct ServerState {
    accept_task: Option<JoinHandle<()>>,
    heartbeat: Option<JoinHandle<()>>,
    bound_port: Option<u16>,
    sessions: HashMap<u64, SessionHandle>,
}

struct SessionHandle {
    peer: String,
    activity: Arc<SessionActivity>,
    shutdown: watch::Sender<bool>,
}

/// Shared between a session task and the idle sweeper.
pub(crate) struct SessionActivity {
    last: Mutex<Instant>,
    transferring: AtomicBool,
}

impl SessionActivity {
    pub(crate) fn touch(&self) {
        *lock(&self.last) = Instant::now();
    }

    pub(crate) fn set_transferring(&self, on: bool) {
        self.transferring.store(on, Ordering::SeqCst);
    }
}

impl FtpServer {
    pub fn new(config: FtpServerConfig) -> Self {
        let (events, _) = broadcast::channel(1024);
        let (files_tx, files_rx) = mpsc::unbounded_channel();
        let cursor = *config.passive_port_range.start();
        Self {
            inner: Arc::new(ServerInner {
                config,
                events,
                files_tx,
                files_rx: Mutex::new(Some(files_rx)),
                state: Mutex::new(ServerState::default()),
                passive_cursor: Mutex::new(cursor),
                next_session: AtomicU64::new(1),
            }),
        }
    }

    pub fn configuration(&self) -> &FtpServerConfig {
        &self.inner.config
    }

    /// A new subscription to server events (no replay of earlier ones).
    pub fn events(&self) -> broadcast::Receiver<FtpServerEvent> {
        self.inner.events.subscribe()
    }

    /// The channel of completed uploads. Single consumer: the first call gets
    /// it, later calls `None`. Files are queued from construction on, so
    /// nothing is lost between `start` and taking the receiver.
    pub fn take_received_files(&self) -> Option<mpsc::UnboundedReceiver<ReceivedFile>> {
        lock(&self.inner.files_rx).take()
    }

    pub fn bound_port(&self) -> Option<u16> {
        lock(&self.inner.state).bound_port
    }

    pub fn is_running(&self) -> bool {
        lock(&self.inner.state).accept_task.is_some()
    }

    pub fn connected_clients(&self) -> usize {
        lock(&self.inner.state).sessions.len()
    }

    /// The Mac's usable IPv4 addresses, most useful first (what cameras dial).
    pub fn advertised_addresses() -> Vec<String> {
        net::local_ipv4_addresses()
    }

    /// The address to show first in the UI, if any.
    pub fn primary_address() -> Option<String> {
        Self::advertised_addresses().into_iter().next()
    }

    /// Creates the root directory, binds the control port and starts
    /// accepting. Returns the bound port. A second call while running is a no-op.
    pub async fn start(&self) -> Result<u16, FtpServerError> {
        if let Some(port) = {
            let st = lock(&self.inner.state);
            st.accept_task.as_ref().and(st.bound_port)
        } {
            return Ok(port);
        }
        let root = &self.inner.config.root_directory;
        tokio::fs::create_dir_all(root)
            .await
            .map_err(|source| FtpServerError::RootDirectory {
                path: root.clone(),
                source,
            })?;
        let port = self.inner.config.port;
        let listener = net::bind_tcp_listener(Ipv4Addr::UNSPECIFIED, port, 8)
            .map_err(|source| FtpServerError::Bind { port, source })?;
        let bound = listener
            .local_addr()
            .map_err(|source| FtpServerError::Bind { port, source })?
            .port();
        let inner = self.inner.clone();
        let every = self.inner.config.heartbeat_interval;
        let heartbeat = tokio::spawn(async move {
            loop {
                tokio::time::sleep(every).await;
                inner.drop_idle_clients();
            }
        });
        {
            let mut st = lock(&self.inner.state);
            st.bound_port = Some(bound);
            st.heartbeat = Some(heartbeat);
        }
        self.inner.install_listener(listener);
        self.inner.emit(FtpServerEvent::Started {
            port: bound,
            addresses: Self::advertised_addresses(),
        });
        Ok(bound)
    }

    /// Closes the listener and every session.
    pub fn stop(&self) {
        let (accept, heartbeat, sessions) = {
            let mut st = lock(&self.inner.state);
            (
                st.accept_task.take(),
                st.heartbeat.take(),
                std::mem::take(&mut st.sessions),
            )
        };
        let Some(accept) = accept else {
            return;
        };
        accept.abort();
        if let Some(h) = heartbeat {
            h.abort();
        }
        for s in sessions.values() {
            let _ = s.shutdown.send(true);
        }
        self.inner.emit(FtpServerEvent::Stopped);
    }

    /// Re-opens the listener on the same port after an IP change so PASV
    /// advertises the new address. Live sessions are untouched.
    pub async fn rebind(&self) {
        let (old, port) = {
            let mut st = lock(&self.inner.state);
            match (st.accept_task.take(), st.bound_port) {
                (Some(t), Some(p)) => (t, p),
                (t, _) => {
                    st.accept_task = t;
                    return;
                }
            }
        };
        old.abort();
        // Let the aborted task drop its listener before re-binding.
        let _ = old.await;
        let mut result = net::bind_tcp_listener(Ipv4Addr::UNSPECIFIED, port, 8);
        if result.is_err() {
            // Port still in TIME_WAIT for a moment: retry once shortly after.
            tokio::time::sleep(Duration::from_millis(200)).await;
            result = net::bind_tcp_listener(Ipv4Addr::UNSPECIFIED, port, 8);
        }
        match result {
            Ok(l) => {
                self.inner.install_listener(l);
                self.inner.emit(FtpServerEvent::Rebound {
                    addresses: Self::advertised_addresses(),
                });
            }
            Err(e) => self.inner.emit(FtpServerEvent::Error(format!(
                "Rebind on port {port} failed: {e}"
            ))),
        }
    }
}

impl Drop for FtpServer {
    fn drop(&mut self) {
        self.stop();
    }
}

impl ServerInner {
    pub(crate) fn emit(&self, event: FtpServerEvent) {
        let _ = self.events.send(event);
    }

    pub(crate) fn deliver(&self, file: ReceivedFile) {
        let _ = self.files_tx.send(file);
    }

    fn install_listener(self: &Arc<Self>, listener: TcpListener) {
        let inner = self.clone();
        let task = tokio::spawn(async move { inner.accept_loop(listener).await });
        lock(&self.state).accept_task = Some(task);
    }

    async fn accept_loop(self: Arc<Self>, listener: TcpListener) {
        loop {
            let (stream, addr) = match listener.accept().await {
                Ok(c) => c,
                Err(e) => {
                    self.emit(FtpServerEvent::Error(format!("Accept failed: {e}")));
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                }
            };
            let peer = addr.ip().to_string();
            let id = self.next_session.fetch_add(1, Ordering::SeqCst);
            let activity = Arc::new(SessionActivity {
                last: Mutex::new(Instant::now()),
                transferring: AtomicBool::new(false),
            });
            let (shutdown, mut shutdown_rx) = watch::channel(false);
            lock(&self.state).sessions.insert(
                id,
                SessionHandle {
                    peer: peer.clone(),
                    activity: activity.clone(),
                    shutdown,
                },
            );
            self.emit(FtpServerEvent::ClientConnected(peer.clone()));
            let inner = self.clone();
            tokio::spawn(async move {
                let session = Session::new(stream, peer, inner.clone(), activity);
                tokio::select! {
                    _ = session.run() => {}
                    _ = shutdown_rx.wait_for(|stop| *stop) => {}
                }
                inner.session_ended(id);
            });
        }
    }

    fn session_ended(&self, id: u64) {
        let ended = lock(&self.state).sessions.remove(&id);
        if let Some(s) = ended {
            self.emit(FtpServerEvent::ClientDisconnected(s.peer));
        }
    }

    fn drop_idle_clients(&self) {
        let idle = self.config.idle_timeout;
        let st = lock(&self.state);
        for s in st.sessions.values() {
            let last = *lock(&s.activity.last);
            if last.elapsed() > idle && !s.activity.transferring.load(Ordering::SeqCst) {
                self.emit(FtpServerEvent::Error(format!(
                    "Dropping idle client {}",
                    s.peer
                )));
                let _ = s.shutdown.send(true);
            }
        }
    }

    /// Binds the next free passive port (rotating through the range); falls
    /// back to an ephemeral port when the range is exhausted.
    pub(crate) fn make_passive_listener(&self) -> std::io::Result<TcpListener> {
        let range = &self.config.passive_port_range;
        let (lo, hi) = (*range.start(), *range.end());
        let count = (hi as usize).saturating_sub(lo as usize) + 1;
        for _ in 0..count {
            let port = {
                let mut c = lock(&self.passive_cursor);
                let p = *c;
                *c = if *c >= hi { lo } else { *c + 1 };
                p
            };
            if let Ok(l) = net::bind_tcp_listener(Ipv4Addr::UNSPECIFIED, port, 1) {
                return Ok(l);
            }
        }
        net::bind_tcp_listener(Ipv4Addr::UNSPECIFIED, 0, 1)
    }
}
