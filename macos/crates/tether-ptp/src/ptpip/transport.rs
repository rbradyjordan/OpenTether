//! PTP/IP transport: command + event TCP connections, the handshake, and
//! demultiplexing of responses, data phases and events.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use tether_types::{CameraVendor, TransportKind};
use tokio::sync::Mutex as AsyncMutex;
use tokio::task::JoinHandle;

use super::channel::{PtpIpChannel, PtpIpConnector, TcpConnector};
use super::packet::{data_phase, PtpIpFramer, PtpIpPacket};
use crate::ptp::transport::lock;
use crate::ptp::{
    EventCode, EventStream, OperationCode, PtpError, PtpEvent, PtpRequest, PtpResponse, PtpResult,
    PtpTransport, ResponseCode, TransportHealth,
};

/// Handshake progress for the connecting screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HandshakeStage {
    TcpConnected,
    InitCommandAcked,
    EventConnected,
    EventAcked,
}

impl HandshakeStage {
    pub const ALL: [HandshakeStage; 4] = [
        Self::TcpConnected,
        Self::InitCommandAcked,
        Self::EventConnected,
        Self::EventAcked,
    ];

    /// Raw values match the iOS enum.
    pub fn raw(self) -> &'static str {
        match self {
            Self::TcpConnected => "tcpConnected",
            Self::InitCommandAcked => "initCommandAcked",
            Self::EventConnected => "eventConnected",
            Self::EventAcked => "eventAcked",
        }
    }
}

/// Connection settings for one camera.
#[derive(Clone)]
pub struct PtpIpConfig {
    pub host: String,
    pub port: u16,
    pub client_name: String,
    pub guid: Vec<u8>,
    pub connect_timeout: Duration,
    pub handshake_timeout: Duration,
    /// Some bodies (older Nikon) answer the event InitEventRequest slowly or
    /// not at all until the first command; allow running without it.
    pub require_event_channel: bool,
    /// Fujifilm cameras dial back to us; the app is then the TCP server and
    /// `host` is ignored by the Fuji connector.
    pub vendor_hint: Option<CameraVendor>,
    /// Handshake progress for the connecting screen.
    pub on_progress: Option<Arc<dyn Fn(HandshakeStage) + Send + Sync>>,
}

impl PtpIpConfig {
    /// Defaults: port 15740, name "Tether", 8 s connect, 15 s handshake,
    /// event channel required.
    pub fn new(host: impl Into<String>, guid: Vec<u8>) -> Self {
        Self {
            host: host.into(),
            port: PtpIpPacket::STANDARD_PORT,
            client_name: "Tether".into(),
            guid,
            connect_timeout: Duration::from_secs(8),
            handshake_timeout: Duration::from_secs(15),
            require_event_channel: true,
            vendor_hint: None,
            on_progress: None,
        }
    }

    fn progress(&self, stage: HandshakeStage) {
        if let Some(f) = &self.on_progress {
            f(stage);
        }
    }
}

impl std::fmt::Debug for PtpIpConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PtpIpConfig")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("client_name", &self.client_name)
            .field("connect_timeout", &self.connect_timeout)
            .field("handshake_timeout", &self.handshake_timeout)
            .field("require_event_channel", &self.require_event_channel)
            .field("vendor_hint", &self.vendor_hint)
            .finish_non_exhaustive()
    }
}

/// PTP/IP transport: two TCP connections to the camera (command + event),
/// the five-packet handshake, and demultiplexing of command responses,
/// data phases and events into separate queues.
///
/// ```text
/// cmd:  InitCommandRequest → InitCommandAck(connectionNumber)
/// evt:  InitEventRequest(connectionNumber) → InitEventAck
/// ```
///
/// After that every transaction is CmdRequest → [StartData, Data*, EndData]
/// → CmdResponse on the command connection; the event connection carries
/// Event packets and the camera's keep-alive probes.
pub struct PtpIpTransport {
    inner: Arc<Inner>,
}

struct Inner {
    config: PtpIpConfig,
    connector: Arc<dyn PtpIpConnector>,
    /// Held for a whole transaction (or the handshake): PTP allows one
    /// outstanding operation per session.
    command: AsyncMutex<CommandState>,
    channels: Mutex<Channels>,
    event_task: Mutex<Option<JoinHandle<()>>>,
    is_open: AtomicBool,
    peer: Mutex<PeerInfo>,
    health: Mutex<TransportHealth>,
    events: EventStream,
}

#[derive(Default)]
struct CommandState {
    framer: PtpIpFramer,
    queued: VecDeque<PtpIpPacket>,
    transaction_id: u32,
}

#[derive(Default)]
struct Channels {
    command: Option<Arc<dyn PtpIpChannel>>,
    event: Option<Arc<dyn PtpIpChannel>>,
}

#[derive(Default, Clone)]
struct PeerInfo {
    connection_number: u32,
    camera_name: String,
    camera_guid: Vec<u8>,
}

impl PtpIpTransport {
    pub fn new(config: PtpIpConfig) -> Self {
        Self::with_connector(config, Arc::new(TcpConnector))
    }

    pub fn with_connector(config: PtpIpConfig, connector: Arc<dyn PtpIpConnector>) -> Self {
        Self {
            inner: Arc::new(Inner {
                config,
                connector,
                command: AsyncMutex::new(CommandState::default()),
                channels: Mutex::new(Channels::default()),
                event_task: Mutex::new(None),
                is_open: AtomicBool::new(false),
                peer: Mutex::new(PeerInfo::default()),
                health: Mutex::new(TransportHealth::default()),
                events: EventStream::default(),
            }),
        }
    }

    pub fn configuration(&self) -> &PtpIpConfig {
        &self.inner.config
    }
    pub fn connection_number(&self) -> u32 {
        lock(&self.inner.peer).connection_number
    }
    pub fn camera_name(&self) -> String {
        lock(&self.inner.peer).camera_name.clone()
    }
    pub fn camera_guid(&self) -> Vec<u8> {
        lock(&self.inner.peer).camera_guid.clone()
    }
    pub fn health(&self) -> TransportHealth {
        lock(&self.inner.health).clone()
    }

    // MARK: Keep-alive

    /// Send a ProbeRequest on the event connection; camera answers ProbeResponse.
    pub async fn probe(&self) -> PtpResult<()> {
        let evt = lock(&self.inner.channels)
            .event
            .clone()
            .ok_or(PtpError::NotConnected)?;
        evt.send(&PtpIpPacket::ProbeRequest.encode()).await
    }
}

impl Inner {
    fn describe_init_fail(reason: u32) -> String {
        match reason {
            1 => "The camera rejected the connection (fail reason 1). Check it is in remote/tether mode.".into(),
            2 => "The camera is busy with another connection. Only one client can control it at a time.".into(),
            3 => "The camera refused this device. Accept the pairing on the camera and try again.".into(),
            _ => format!("The camera refused the connection (reason {reason})."),
        }
    }

    fn set_last_error(&self, e: impl ToString) {
        lock(&self.health).last_error = Some(e.to_string());
    }

    /// Tears the link down without waiting for an in-flight transaction:
    /// closing the channels wakes it with `TransportClosed`.
    fn close_now(&self) {
        self.is_open.store(false, Ordering::SeqCst);
        if let Some(t) = lock(&self.event_task).take() {
            t.abort();
        }
        let (cmd, evt) = {
            let mut ch = lock(&self.channels);
            (ch.command.take(), ch.event.take())
        };
        if let Some(c) = cmd {
            c.close();
        }
        if let Some(e) = evt {
            e.close();
        }
        if let Ok(mut st) = self.command.try_lock() {
            st.queued.clear();
            st.framer = PtpIpFramer::new();
        }
    }

    async fn next_command_packet(
        st: &mut CommandState,
        cmd: &Arc<dyn PtpIpChannel>,
    ) -> PtpResult<PtpIpPacket> {
        loop {
            if let Some(p) = st.queued.pop_front() {
                return Ok(p);
            }
            let chunk = cmd.receive().await?;
            st.framer.append(&chunk);
            st.queued.extend(st.framer.drain()?);
        }
    }

    async fn open(self: &Arc<Self>) -> PtpResult<()> {
        if self.is_open.load(Ordering::SeqCst) {
            return Ok(());
        }
        let mut st = self.command.lock().await;
        if self.is_open.load(Ordering::SeqCst) {
            return Ok(());
        }
        *st = CommandState::default();
        let cfg = &self.config;
        let cmd = self
            .connector
            .connect(&cfg.host, cfg.port, cfg.connect_timeout)
            .await?;
        lock(&self.channels).command = Some(cmd.clone());
        cfg.progress(HandshakeStage::TcpConnected);
        let result = self.handshake(&mut st, &cmd).await;
        drop(st);
        if let Err(e) = result {
            self.set_last_error(&e);
            self.close_now();
            return Err(e);
        }
        Ok(())
    }

    async fn handshake(
        self: &Arc<Self>,
        st: &mut CommandState,
        cmd: &Arc<dyn PtpIpChannel>,
    ) -> PtpResult<()> {
        let cfg = &self.config;
        cmd.send(
            &PtpIpPacket::InitCommandRequest {
                guid: cfg.guid.clone(),
                name: cfg.client_name.clone(),
                protocol_version: PtpIpPacket::PROTOCOL_VERSION,
            }
            .encode(),
        )
        .await?;
        let ack = tokio::time::timeout(
            cfg.handshake_timeout.max(Duration::from_millis(50)),
            Self::next_command_packet(st, cmd),
        )
        .await
        .map_err(|_| PtpError::Timeout {
            op: OperationCode::OPEN_SESSION,
        })??;
        match ack {
            PtpIpPacket::InitCommandAck {
                connection_number,
                guid,
                name,
                ..
            } => {
                *lock(&self.peer) = PeerInfo {
                    connection_number,
                    camera_name: name,
                    camera_guid: guid,
                };
                cfg.progress(HandshakeStage::InitCommandAcked);
            }
            PtpIpPacket::InitFail { reason } => {
                return Err(PtpError::VendorGate(Self::describe_init_fail(reason)))
            }
            other => {
                return Err(PtpError::Malformed(format!(
                    "Expected InitCommandAck, got {:?}",
                    other.packet_type()
                )))
            }
        }

        let evt = self
            .connector
            .connect(&cfg.host, cfg.port, cfg.connect_timeout)
            .await?;
        lock(&self.channels).event = Some(evt.clone());
        cfg.progress(HandshakeStage::EventConnected);
        let connection_number = lock(&self.peer).connection_number;
        evt.send(&PtpIpPacket::InitEventRequest { connection_number }.encode())
            .await?;

        let mut framer = PtpIpFramer::new();
        let mut acked = false;
        let wait = if cfg.require_event_channel {
            cfg.handshake_timeout
        } else {
            Duration::from_secs(2)
        };
        let ack_result = tokio::time::timeout(wait.max(Duration::from_millis(50)), async {
            while !acked {
                framer.append(&evt.receive().await?);
                for p in framer.drain()? {
                    match p {
                        PtpIpPacket::InitEventAck => acked = true,
                        PtpIpPacket::InitFail { reason } => {
                            return Err(PtpError::VendorGate(Self::describe_init_fail(reason)))
                        }
                        _ => {}
                    }
                }
            }
            Ok(())
        })
        .await;
        match ack_result {
            Ok(r) => r?,
            // Proceed without a confirmed event channel when allowed.
            Err(_) if !cfg.require_event_channel => {}
            Err(_) => {
                return Err(PtpError::Timeout {
                    op: OperationCode::OPEN_SESSION,
                })
            }
        }
        self.is_open.store(true, Ordering::SeqCst);
        self.start_event_loop(evt, framer);
        if acked {
            cfg.progress(HandshakeStage::EventAcked);
        }
        Ok(())
    }

    fn start_event_loop(self: &Arc<Self>, evt: Arc<dyn PtpIpChannel>, initial: PtpIpFramer) {
        let weak: Weak<Inner> = Arc::downgrade(self);
        let events = self.events.clone();
        let task = tokio::spawn(async move {
            let mut framer = initial;
            loop {
                let step: PtpResult<()> = async {
                    framer.append(&evt.receive().await?);
                    for p in framer.drain()? {
                        match p {
                            PtpIpPacket::Event {
                                code,
                                transaction_id,
                                parameters,
                            } => events.push(
                                PtpEvent::new(code, parameters).with_transaction_id(transaction_id),
                            ),
                            PtpIpPacket::ProbeRequest => {
                                let _ = evt.send(&PtpIpPacket::ProbeResponse.encode()).await;
                            }
                            _ => {}
                        }
                    }
                    Ok(())
                }
                .await;
                if let Err(e) = step {
                    let Some(inner) = weak.upgrade() else { return };
                    if !inner.is_open.load(Ordering::SeqCst) {
                        return;
                    }
                    inner.set_last_error(format!("event channel: {e}"));
                    events.push(PtpEvent::new(EventCode::DEVICE_RESET, []));
                    // Detach our own handle first so close_now does not abort us.
                    lock(&inner.event_task).take();
                    inner.close_now();
                    return;
                }
            }
        });
        *lock(&self.event_task) = Some(task);
    }

    async fn execute(&self, request: PtpRequest) -> PtpResult<PtpResponse> {
        let mut st = self.command.lock().await;
        let cmd = lock(&self.channels).command.clone();
        let cmd = match cmd {
            Some(c) if self.is_open.load(Ordering::SeqCst) => c,
            _ => return Err(PtpError::NotConnected),
        };
        st.transaction_id = st.transaction_id.wrapping_add(1);
        if st.transaction_id == 0 {
            st.transaction_id = 1;
        }
        let tid = st.transaction_id;
        let started = Instant::now();

        let phase = if request.data_out.is_none() {
            data_phase::NO_DATA_OR_DATA_IN
        } else {
            data_phase::DATA_OUT
        };
        cmd.send(
            &PtpIpPacket::CmdRequest {
                data_phase: phase,
                code: request.code,
                transaction_id: tid,
                parameters: request.parameters.clone(),
            }
            .encode(),
        )
        .await?;
        lock(&self.health).bytes_out += 8 + 10 + request.parameters.len() * 4;

        if let Some(out) = &request.data_out {
            cmd.send(
                &PtpIpPacket::StartData {
                    transaction_id: tid,
                    total_length: out.len() as u64,
                }
                .encode(),
            )
            .await?;
            // Send everything in one EndData; cameras accept any split.
            cmd.send(
                &PtpIpPacket::EndData {
                    transaction_id: tid,
                    payload: out.clone(),
                }
                .encode(),
            )
            .await?;
            lock(&self.health).bytes_out += out.len() + 20;
        }

        let receive = async {
            let mut data_in: Vec<u8> = Vec::new();
            let mut expected: Option<u64> = None;
            loop {
                match Self::next_command_packet(&mut st, &cmd).await? {
                    PtpIpPacket::StartData {
                        transaction_id,
                        total_length,
                    } if transaction_id == tid => {
                        expected = Some(total_length);
                        if total_length < 1 << 31 {
                            data_in.reserve(total_length as usize);
                        }
                    }
                    PtpIpPacket::Data {
                        transaction_id,
                        payload,
                    }
                    | PtpIpPacket::EndData {
                        transaction_id,
                        payload,
                    } if transaction_id == tid => data_in.extend_from_slice(&payload),
                    PtpIpPacket::CmdResponse {
                        code,
                        transaction_id,
                        parameters,
                    } if transaction_id == tid => {
                        {
                            let mut h = lock(&self.health);
                            h.bytes_in += data_in.len();
                            h.round_trip_millis = Some(started.elapsed().as_secs_f64() * 1000.0);
                        }
                        if let Some(e) = expected {
                            // Some bodies under-report; only fail when we got less.
                            if code == ResponseCode::OK && (data_in.len() as u64) < e {
                                return Err(PtpError::Malformed(format!(
                                    "data phase short: {} of {e}",
                                    data_in.len()
                                )));
                            }
                        }
                        return Ok(PtpResponse {
                            code,
                            parameters,
                            data_in,
                            transaction_id: tid,
                        });
                    }
                    PtpIpPacket::Event {
                        code,
                        transaction_id,
                        parameters,
                    } => {
                        // Some cameras push events on the command connection.
                        self.events.push(
                            PtpEvent::new(code, parameters).with_transaction_id(transaction_id),
                        );
                    }
                    PtpIpPacket::ProbeRequest => {
                        cmd.send(&PtpIpPacket::ProbeResponse.encode()).await?;
                    }
                    PtpIpPacket::CancelTransaction { transaction_id } if transaction_id == tid => {
                        return Err(PtpError::Cancelled);
                    }
                    // Stale packet from an earlier, timed-out transaction: drop it.
                    _ => continue,
                }
            }
        };
        let result = tokio::time::timeout(request.timeout.max(Duration::from_millis(50)), receive)
            .await
            .unwrap_or(Err(PtpError::Timeout { op: request.code }));
        if let Err(e @ PtpError::Timeout { .. }) = &result {
            self.set_last_error(e);
            drop(st);
            self.close_now();
        }
        result
    }
}

#[async_trait]
impl PtpTransport for PtpIpTransport {
    fn kind(&self) -> TransportKind {
        TransportKind::PtpIp
    }

    fn is_open(&self) -> bool {
        self.inner.is_open.load(Ordering::SeqCst)
    }

    async fn open(&self) -> PtpResult<()> {
        self.inner.open().await
    }

    async fn close(&self) {
        self.inner.close_now();
    }

    async fn execute(&self, request: PtpRequest) -> PtpResult<PtpResponse> {
        self.inner.execute(request).await
    }

    fn events(&self) -> EventStream {
        self.inner.events.clone()
    }
}

impl Drop for PtpIpTransport {
    fn drop(&mut self) {
        self.inner.close_now();
    }
}
