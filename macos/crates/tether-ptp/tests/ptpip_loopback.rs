//! Port of `PTPIPTests.swift`: a fake PTP/IP camera on 127.0.0.1 answers the
//! handshake, OpenSession, GetDeviceInfo, data-in and data-out phases, and
//! pushes an event.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use tether_ptp::ptp::*;
use tether_ptp::ptpip::*;
use tether_ptp::testing::{fake_jpeg, generic_info};
use tokio::net::TcpListener;

/// A minimal PTP/IP camera on loopback: accepts the two connections, runs the
/// handshake and answers GetDeviceInfo / OpenSession / GetObject, pushing one
/// ObjectAdded event after the session opens.
struct FakePtpIpCamera {
    port: u16,
    object_payload: Vec<u8>,
    state: Arc<Mutex<CamState>>,
    task: tokio::task::JoinHandle<()>,
}

const CONNECTION_NUMBER: u32 = 0x1001;

#[derive(Default)]
struct CamState {
    event_channel: Option<Arc<dyn PtpIpChannel>>,
    /// Data-out payloads received, by transaction.
    data_out: Vec<Vec<u8>>,
}

impl FakePtpIpCamera {
    async fn start(refuse: bool, answer_event_channel: bool) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let object_payload = fake_jpeg(300_000);
        let payload = object_payload.clone();
        let state = Arc::new(Mutex::new(CamState::default()));
        let cam_state = state.clone();
        let task = tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let ch: Arc<dyn PtpIpChannel> = Arc::new(TcpChannel::new(stream));
                let st = state.clone();
                let p = payload.clone();
                tokio::spawn(async move {
                    let _ = serve(ch.clone(), st, p, refuse, answer_event_channel).await;
                    ch.close();
                });
            }
        });
        Self {
            port,
            object_payload,
            state: cam_state,
            task,
        }
    }

    fn stop(&self) {
        self.task.abort();
    }

    /// The camera drops its event connection (powered off, out of range).
    fn drop_event_channel(&self) {
        if let Some(ch) = self.state.lock().unwrap().event_channel.take() {
            ch.close();
        }
    }

    fn data_out(&self) -> Vec<Vec<u8>> {
        self.state.lock().unwrap().data_out.clone()
    }
}

async fn serve(
    ch: Arc<dyn PtpIpChannel>,
    state: Arc<Mutex<CamState>>,
    payload: Vec<u8>,
    refuse: bool,
    answer_event_channel: bool,
) -> PtpResult<()> {
    let mut framer = PtpIpFramer::new();
    let mut session_open = false;
    let mut pending_out: Vec<u8> = Vec::new();
    // A data-out command is answered once its EndData has arrived.
    let mut pending_cmd: Option<(OperationCode, u32, Vec<u32>)> = None;
    loop {
        framer.append(&ch.receive().await?);
        for p in framer.drain()? {
            let command = match p {
                PtpIpPacket::InitCommandRequest { .. } => {
                    if refuse {
                        ch.send(&PtpIpPacket::InitFail { reason: 2 }.encode())
                            .await?;
                        return Ok(());
                    }
                    ch.send(
                        &PtpIpPacket::InitCommandAck {
                            connection_number: CONNECTION_NUMBER,
                            guid: vec![9; 16],
                            name: "FakeCam".into(),
                            protocol_version: PtpIpPacket::PROTOCOL_VERSION,
                        }
                        .encode(),
                    )
                    .await?;
                    None
                }
                PtpIpPacket::InitEventRequest { connection_number } => {
                    if connection_number != CONNECTION_NUMBER {
                        ch.send(&PtpIpPacket::InitFail { reason: 1 }.encode())
                            .await?;
                        return Ok(());
                    }
                    state.lock().unwrap().event_channel = Some(ch.clone());
                    if answer_event_channel {
                        ch.send(&PtpIpPacket::InitEventAck.encode()).await?;
                    }
                    None
                }
                PtpIpPacket::StartData { .. } => {
                    pending_out.clear();
                    None
                }
                PtpIpPacket::Data { payload: d, .. } => {
                    pending_out.extend(d);
                    None
                }
                PtpIpPacket::EndData { payload: d, .. } => {
                    pending_out.extend(d);
                    state
                        .lock()
                        .unwrap()
                        .data_out
                        .push(std::mem::take(&mut pending_out));
                    pending_cmd.take()
                }
                PtpIpPacket::CmdRequest {
                    code,
                    transaction_id,
                    parameters,
                    data_phase: phase,
                } => {
                    if phase == data_phase::DATA_OUT {
                        pending_cmd = Some((code, transaction_id, parameters));
                        None
                    } else {
                        Some((code, transaction_id, parameters))
                    }
                }
                PtpIpPacket::ProbeRequest => {
                    ch.send(&PtpIpPacket::ProbeResponse.encode()).await?;
                    None
                }
                _ => None,
            };
            let Some((code, tid, parameters)) = command else {
                continue;
            };
            match code {
                OperationCode::GET_DEVICE_INFO => {
                    reply(&ch, tid, &generic_info().encoded(), 1 << 20).await?
                }
                OperationCode::OPEN_SESSION => {
                    session_open = true;
                    respond(&ch, tid, ResponseCode::OK).await?;
                    let evt = state.lock().unwrap().event_channel.clone();
                    if let Some(evt) = evt {
                        evt.send(
                            &PtpIpPacket::Event {
                                code: EventCode::OBJECT_ADDED,
                                transaction_id: 0,
                                parameters: vec![0x77],
                            }
                            .encode(),
                        )
                        .await?;
                    }
                }
                OperationCode::GET_OBJECT_INFO => {
                    let info = PtpObjectInfo {
                        object_format: ObjectFormat::EXIF_JPEG,
                        object_compressed_size: payload.len() as u32,
                        filename: "FAKE0001.JPG".into(),
                        ..Default::default()
                    };
                    reply(&ch, tid, &info.encoded(), 1 << 20).await?;
                }
                OperationCode::GET_OBJECT => reply(&ch, tid, &payload, 65536).await?,
                OperationCode::GET_PARTIAL_OBJECT => {
                    let off = parameters[1] as usize;
                    let want = parameters[2] as usize;
                    let end = payload.len().min(off + want);
                    reply(&ch, tid, &payload[off..end], 1 << 20).await?;
                }
                OperationCode::SET_DEVICE_PROP_VALUE => respond(&ch, tid, ResponseCode::OK).await?,
                OperationCode::CLOSE_SESSION => {
                    session_open = false;
                    respond(&ch, tid, ResponseCode::OK).await?;
                }
                OperationCode::GET_STORAGE_IDS => {
                    // Never answers: exercises the transaction timeout.
                }
                _ => {
                    let code = if session_open {
                        ResponseCode::OPERATION_NOT_SUPPORTED
                    } else {
                        ResponseCode::SESSION_NOT_OPEN
                    };
                    respond(&ch, tid, code).await?;
                }
            }
        }
    }
}

async fn respond(ch: &Arc<dyn PtpIpChannel>, tid: u32, code: ResponseCode) -> PtpResult<()> {
    ch.send(
        &PtpIpPacket::CmdResponse {
            code,
            transaction_id: tid,
            parameters: vec![],
        }
        .encode(),
    )
    .await
}

async fn reply(ch: &Arc<dyn PtpIpChannel>, tid: u32, data: &[u8], chunk: usize) -> PtpResult<()> {
    ch.send(
        &PtpIpPacket::StartData {
            transaction_id: tid,
            total_length: data.len() as u64,
        }
        .encode(),
    )
    .await?;
    let mut off = 0;
    while off < data.len() {
        let end = data.len().min(off + chunk);
        let slice = data[off..end].to_vec();
        let p = if end == data.len() {
            PtpIpPacket::EndData {
                transaction_id: tid,
                payload: slice,
            }
        } else {
            PtpIpPacket::Data {
                transaction_id: tid,
                payload: slice,
            }
        };
        ch.send(&p.encode()).await?;
        off = end;
    }
    respond(ch, tid, ResponseCode::OK).await
}

fn config(port: u16) -> PtpIpConfig {
    let mut cfg = PtpIpConfig::new("127.0.0.1", PtpIpIdentity::guid(&uuid::Uuid::new_v4()));
    cfg.port = port;
    cfg
}

#[tokio::test]
async fn handshake_transactions_and_events() {
    let cam = FakePtpIpCamera::start(false, true).await;
    let stages = Arc::new(Mutex::new(Vec::new()));
    let s2 = stages.clone();
    let mut cfg = config(cam.port);
    cfg.on_progress = Some(Arc::new(move |s| s2.lock().unwrap().push(s)));
    let transport = Arc::new(PtpIpTransport::new(cfg));
    let engine = PtpEngine::new(transport.clone());
    let info = engine.connect(1).await.unwrap();
    assert_eq!(info.model, "PTP-1");
    assert_eq!(transport.camera_name(), "FakeCam");
    assert_eq!(transport.connection_number(), CONNECTION_NUMBER);
    assert_eq!(transport.camera_guid(), vec![9; 16]);
    assert_eq!(*stages.lock().unwrap(), HandshakeStage::ALL.to_vec());

    // Event pushed on the event channel after OpenSession.
    let ev = tokio::time::timeout(Duration::from_secs(5), transport.events().next())
        .await
        .expect("event in time")
        .unwrap();
    assert_eq!(ev.code, EventCode::OBJECT_ADDED);
    assert_eq!(ev.parameters.first(), Some(&0x77));

    // Multi-packet data phase reassembles.
    let obj = engine.get_object_info(0x77).await.unwrap();
    assert_eq!(obj.filename, "FAKE0001.JPG");
    let data = engine.get_object(0x77, None).await.unwrap();
    assert_eq!(data, cam.object_payload);
    let partial = engine
        .download(0x77, Some(obj.object_compressed_size), None)
        .await
        .unwrap();
    assert_eq!(partial, cam.object_payload);

    // Data-out phase.
    engine
        .set_device_prop_value(DevicePropCode::F_NUMBER, &PtpValue::UInt16(280))
        .await
        .unwrap();
    assert_eq!(cam.data_out(), vec![PtpValue::UInt16(280).encoded()]);

    // Keep-alive probe on the event channel doesn't disturb anything.
    transport.probe().await.unwrap();

    // Unsupported op maps to a PtpError with the code.
    let e = engine
        .run(OperationCode::FORMAT_STORE, &[1])
        .await
        .unwrap_err();
    assert_eq!(
        e.response_code(),
        Some(ResponseCode::OPERATION_NOT_SUPPORTED)
    );
    assert!(transport.health().bytes_in >= cam.object_payload.len() * 2);

    engine.disconnect().await;
    assert!(!transport.is_open());
    assert!(matches!(
        engine.get_storage_ids().await,
        Err(PtpError::NotConnected)
    ));
    cam.stop();
}

#[tokio::test]
async fn init_fail_surfaces_as_gate() {
    let cam = FakePtpIpCamera::start(true, true).await;
    let transport = PtpIpTransport::new(config(cam.port));
    match transport.open().await {
        Err(PtpError::VendorGate(msg)) => assert!(msg.contains("busy"), "{msg}"),
        other => panic!("expected refusal, got {other:?}"),
    }
    assert!(!transport.is_open());
    assert!(transport.health().last_error.is_some());
    cam.stop();
}

#[tokio::test]
async fn connection_refused_is_reported() {
    // Bind then drop a listener to get a port nothing listens on.
    let port = {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        l.local_addr().unwrap().port()
    };
    let mut cfg = config(port);
    cfg.connect_timeout = Duration::from_secs(2);
    let transport = PtpIpTransport::new(cfg);
    assert!(matches!(transport.open().await, Err(PtpError::Channel(_))));
}

#[tokio::test]
async fn optional_event_channel_and_transaction_timeout() {
    // The camera never acks the event channel: allowed when not required.
    let cam = FakePtpIpCamera::start(false, false).await;
    let mut cfg = config(cam.port);
    cfg.require_event_channel = false;
    let transport = Arc::new(PtpIpTransport::new(cfg));
    let engine = PtpEngine::new(transport.clone());
    engine.connect(1).await.unwrap();
    assert!(transport.is_open());

    // A request the camera never answers times out and closes the link,
    // with a DeviceReset-free shutdown (we closed it ourselves).
    let req = PtpRequest::new(OperationCode::GET_STORAGE_IDS, [])
        .with_timeout(Duration::from_millis(300));
    assert!(matches!(
        engine.execute(req).await,
        Err(PtpError::Timeout {
            op: OperationCode::GET_STORAGE_IDS
        })
    ));
    assert!(!transport.is_open());
    cam.stop();

    // Required event channel without an ack: the handshake times out.
    let cam = FakePtpIpCamera::start(false, false).await;
    let mut cfg = config(cam.port);
    cfg.handshake_timeout = Duration::from_millis(300);
    let transport = PtpIpTransport::new(cfg);
    assert!(matches!(
        transport.open().await,
        Err(PtpError::Timeout { .. })
    ));
    assert!(!transport.is_open());
    cam.stop();
}

#[tokio::test]
async fn event_channel_loss_reports_device_reset() {
    let cam = FakePtpIpCamera::start(false, true).await;
    let transport = Arc::new(PtpIpTransport::new(config(cam.port)));
    let engine = PtpEngine::new(transport.clone());
    engine.connect(1).await.unwrap();
    let events = transport.events();
    // The ObjectAdded pushed after OpenSession.
    let first = tokio::time::timeout(Duration::from_secs(5), events.next())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(first.code, EventCode::OBJECT_ADDED);
    cam.drop_event_channel();
    let ev = tokio::time::timeout(Duration::from_secs(5), events.next())
        .await
        .expect("DeviceReset in time")
        .unwrap();
    assert_eq!(ev.code, EventCode::DEVICE_RESET);
    assert!(!transport.is_open());
    assert!(transport
        .health()
        .last_error
        .is_some_and(|e| e.starts_with("event channel")));
    cam.stop();
}
