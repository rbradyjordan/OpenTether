//! Discovery tests ported from the Swift `Discovery/` test files, plus
//! loopback runs of the Fuji dial-back and the HTTP probes against a local server.

mod common;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use common::{http_server, wait_until, FakeProber};
use tether_net::discovery::{FujiOptions, SsdpDeviceDescription};
use tether_net::{
    BonjourDiscoverer, CameraDiscoverer, CameraDiscovering, DiscoveredCamera, DiscoveryError,
    DiscoveryMethod, DiscoveryState, FujiDiscoverer, HttpCameraProbe, ProbeError, ReqwestProber,
    RicohProbe, SsdpDiscoverer, PTPIP_STANDARD_PORT,
};
use tether_types::{CameraVendor, TransportKind};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

// MARK: - SSDP

const SONY_RESPONSE: &str = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\nLOCATION: http://192.168.122.1:64321/dd.xml\r\nSERVER: UPnP/1.0 SonyImagingDevice/1.0\r\nST: urn:schemas-sony-com:service:ScalarWebAPI:1\r\nUSN: uuid:00000000-0005-0010-8000-1c994c1b4f3a::urn:schemas-sony-com:service:ScalarWebAPI:1\r\nX-AV-Physical-Unit-Info: pa=\"ILCE-7M4\";\r\n\r\n";
const SONY_NOTIFY: &str = "NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nNT: upnp:rootdevice\r\nNTS: ssdp:alive\r\nLOCATION: http://192.168.122.1:64321/dd.xml\r\nUSN: uuid:00000000-0005-0010-8000-1c994c1b4f3a::upnp:rootdevice\r\n\r\n";

const SONY_XML: &str = r#"<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:av="urn:schemas-sony-com:av">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
    <friendlyName>ILCE-7M4</friendlyName>
    <manufacturer>Sony Corporation</manufacturer>
    <modelName>SonyImagingDevice</modelName>
    <UDN>uuid:00000000-0005-0010-8000-1c994c1b4f3a</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-sony-com:service:ScalarWebAPI:1</serviceType>
        <serviceId>urn:schemas-sony-com:serviceId:ScalarWebAPI</serviceId>
        <SCPDURL>/ScalarWebAPI.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-sony-com:service:DigitalImaging:1</serviceType>
        <serviceId>urn:schemas-sony-com:serviceId:DigitalImaging</serviceId>
      </service>
    </serviceList>
    <av:X_ScalarWebAPI_DeviceInfo>
      <av:X_ScalarWebAPI_ServiceList>
        <av:X_ScalarWebAPI_Service>
          <av:X_ScalarWebAPI_ServiceType>camera</av:X_ScalarWebAPI_ServiceType>
          <av:X_ScalarWebAPI_ActionList_URL>http://192.168.122.1:8080/sony</av:X_ScalarWebAPI_ActionList_URL>
        </av:X_ScalarWebAPI_Service>
      </av:X_ScalarWebAPI_ServiceList>
    </av:X_ScalarWebAPI_DeviceInfo>
  </device>
</root>"#;

const ROUTER_XML: &str = r#"<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"><device>
  <friendlyName>Router</friendlyName><manufacturer>Acme</manufacturer><modelName>R1</modelName>
  <UDN>uuid:router</UDN>
  <serviceList><service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType></service></serviceList>
</device></root>"#;

#[test]
fn device_description_parsing() {
    let d = SsdpDeviceDescription::parse(SONY_XML.as_bytes()).unwrap();
    assert_eq!(d.friendly_name, "ILCE-7M4");
    assert_eq!(d.manufacturer, "Sony Corporation");
    assert_eq!(d.model_name, "SonyImagingDevice");
    assert_eq!(d.udn, "uuid:00000000-0005-0010-8000-1c994c1b4f3a");
    assert_eq!(
        d.service_types,
        [
            "urn:schemas-sony-com:service:ScalarWebAPI:1",
            "urn:schemas-sony-com:service:DigitalImaging:1"
        ]
    );
    assert_eq!(d.scalar_web_api_urls, ["http://192.168.122.1:8080/sony"]);
    assert!(d.is_sony_imaging());

    let r = SsdpDeviceDescription::parse(ROUTER_XML.as_bytes()).unwrap();
    assert!(!r.is_sony_imaging());
    assert_eq!(r.friendly_name, "Router");
    assert!(SsdpDeviceDescription::parse(b"<nope/>").is_none());
    assert!(SsdpDeviceDescription::parse(b"not xml at all").is_none());
}

#[test]
fn embedded_devices_do_not_override_root_identity() {
    let xml = r#"<root><device><friendlyName>Root</friendlyName>
        <deviceList><device><friendlyName>Child</friendlyName>
        <serviceList><service><serviceType>urn:schemas-sony-com:service:DigitalImaging:1</serviceType></service></serviceList>
        </device></deviceList></device></root>"#;
    let d = SsdpDeviceDescription::parse(xml.as_bytes()).unwrap();
    assert_eq!(d.friendly_name, "Root");
    assert!(d.is_sony_imaging());
}

#[tokio::test]
async fn ssdp_accepts_sony_after_description_check() {
    let prober = FakeProber::new(&[(
        "http://192.168.122.1:64321/dd.xml",
        SONY_XML.as_bytes(),
        200,
    )]);
    let d = SsdpDiscoverer::with_prober(prober.clone());
    d.ingest(SONY_RESPONSE, "192.168.122.1").await;
    let cams = d.current();
    assert_eq!(cams.len(), 1);
    let cam = &cams[0];
    assert_eq!(cam.id, "00000000-0005-0010-8000-1c994c1b4f3a");
    assert_eq!(cam.vendor, Some(CameraVendor::Sony));
    assert_eq!(cam.transport, TransportKind::PtpIp);
    assert_eq!(cam.port, 15740);
    assert_eq!(cam.host, "192.168.122.1");
    assert_eq!(cam.method, DiscoveryMethod::Ssdp);
    assert_eq!(cam.name, "ILCE-7M4");
    assert_eq!(cam.details["location"], "http://192.168.122.1:64321/dd.xml");
    assert_eq!(cam.details["model"], "SonyImagingDevice");
    assert_eq!(
        cam.details["scalarWebAPI"],
        "http://192.168.122.1:8080/sony"
    );

    // Same device via NOTIFY dedupes by UUID; byebye removes it.
    d.ingest(SONY_NOTIFY, "192.168.122.1").await;
    assert_eq!(d.current().len(), 1);
    d.ingest(
        "NOTIFY * HTTP/1.1\r\nNTS: ssdp:byebye\r\nUSN: uuid:00000000-0005-0010-8000-1c994c1b4f3a::upnp:rootdevice\r\n\r\n",
        "192.168.122.1",
    )
    .await;
    assert_eq!(d.current().len(), 0);
    assert_eq!(prober.call_count(), 2);
}

#[tokio::test]
async fn ssdp_rejects_non_sony_and_apipa() {
    let prober = FakeProber::new(&[("http://192.168.1.1/desc.xml", ROUTER_XML.as_bytes(), 200)]);
    let d = SsdpDiscoverer::with_prober(prober.clone());
    d.ingest(
        "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.1/desc.xml\r\nST: upnp:rootdevice\r\nUSN: uuid:router::upnp:rootdevice\r\n\r\n",
        "192.168.1.1",
    )
    .await;
    assert_eq!(d.current().len(), 0);
    assert_eq!(prober.call_count(), 1);
    d.ingest(
        "HTTP/1.1 200 OK\r\nLOCATION: http://169.254.3.4/dd.xml\r\nST: urn:schemas-sony-com:service:ScalarWebAPI:1\r\nUSN: uuid:x::y\r\n\r\n",
        "169.254.3.4",
    )
    .await;
    assert_eq!(
        prober.call_count(),
        1,
        "link-local LOCATION must not be fetched"
    );
    // Non-camera noise (a printer) is not even fetched.
    d.ingest(
        "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.9/p.xml\r\nST: urn:schemas-upnp-org:service:Printer:1\r\nUSN: uuid:p::q\r\n\r\n",
        "192.168.1.9",
    )
    .await;
    assert_eq!(prober.call_count(), 1);
    assert_eq!(d.current().len(), 0);
}

/// Real HTTP fetch of the description through reqwest. LOCATION must be a
/// usable (non-loopback) address, so this needs a LAN interface.
#[tokio::test]
async fn ssdp_fetches_description_over_http() {
    let port = http_server("0.0.0.0", vec![("/dd.xml", SONY_XML.as_bytes().to_vec())]).await;
    // Pick a LAN address this process can actually reach (sandboxes and
    // macOS local-network privacy can block some).
    let mut lan = None;
    for a in CameraDiscoverer::local_ipv4_addresses() {
        let ok = tokio::time::timeout(
            Duration::from_millis(500),
            TcpStream::connect((a.as_str(), port)),
        )
        .await;
        if matches!(ok, Ok(Ok(_))) {
            lan = Some(a);
            break;
        }
    }
    let Some(lan) = lan else {
        eprintln!("skipped: no reachable LAN interface");
        return;
    };
    let d = SsdpDiscoverer::with_prober(Arc::new(ReqwestProber::new()));
    let msg = SONY_RESPONSE.replace("192.168.122.1:64321", &format!("{lan}:{port}"));
    d.ingest(&msg, &lan).await;
    let cams = d.current();
    assert_eq!(cams.len(), 1, "{:?}", d.last_error());
    assert_eq!(cams[0].host, lan);
    assert_eq!(cams[0].name, "ILCE-7M4");
}

#[tokio::test]
async fn ssdp_start_stop() {
    let d = SsdpDiscoverer::with_prober(FakeProber::new(&[]));
    if let Err(e) = d.start().await {
        eprintln!("skipped: UDP unavailable: {e}");
        return;
    }
    d.send_searches().await;
    d.stop().await;
    assert_eq!(d.current().len(), 0);
}

// MARK: - Ricoh / GoPro / OSC probes

const RICOH_PROPS: &str = r#"{"errCode":200,"errMsg":"OK","model":"RICOH GR IIIx","firmwareVersion":"1.50","serialNumber":"1234567","batteryLevel":80}"#;

#[tokio::test]
async fn ricoh_probe_emits_and_clears() {
    let prober = FakeProber::new(&[(RicohProbe::DEFAULT_URL, RICOH_PROPS.as_bytes(), 200)]);
    let p = RicohProbe::with_prober(prober.clone(), RicohProbe::DEFAULT_URL);
    p.probe_once().await;
    assert_eq!(p.current().len(), 1);
    assert_eq!(p.current()[0].name, "RICOH GR IIIx");
    assert_eq!(p.current()[0].host, "192.168.0.1");
    // Camera goes away (timeout) → list empties, error recorded.
    prober.set_error(Some(ProbeError::Timeout));
    p.probe_once().await;
    assert_eq!(p.current().len(), 0);
    assert!(p.last_error().is_some());
    // A 200 without a model is not a camera.
    prober.set_error(None);
    prober.set(RicohProbe::DEFAULT_URL, b"{}", 200);
    p.probe_once().await;
    assert_eq!(p.current().len(), 0);
}

#[tokio::test]
async fn ricoh_probe_against_local_http_server() {
    let port = http_server(
        "127.0.0.1",
        vec![("/v1/props", RICOH_PROPS.as_bytes().to_vec())],
    )
    .await;
    let url = format!("http://127.0.0.1:{port}/v1/props");
    let p = RicohProbe::with_prober(Arc::new(ReqwestProber::new()), url);
    p.probe_once().await;
    let cams = p.current();
    assert_eq!(cams.len(), 1, "{:?}", p.last_error());
    assert_eq!(cams[0].id, "127.0.0.1");
    assert_eq!(cams[0].details["serialNumber"], "1234567");
    // Nothing listening → cleared and error recorded.
    let dead = RicohProbe::with_prober(
        Arc::new(ReqwestProber::new()),
        "http://127.0.0.1:9/v1/props",
    );
    dead.probe_once().await;
    assert!(dead.current().is_empty());
    assert!(dead.last_error().is_some());
}

#[tokio::test]
async fn gopro_and_osc_probes_against_local_http_servers() {
    let gopro = http_server(
        "127.0.0.1",
        vec![(
            "/gopro/camera/info",
            br#"{"info":{"model_name":"HERO12 Black","serial_number":"C1"}}"#.to_vec(),
        )],
    )
    .await;
    let osc = http_server(
        "127.0.0.1",
        vec![(
            "/osc/info",
            br#"{"model":"RICOH THETA X","manufacturer":"Ricoh"}"#.to_vec(),
        )],
    )
    .await;
    let empty = http_server("127.0.0.1", vec![]).await;
    let p = HttpCameraProbe::with_hosts(
        Arc::new(ReqwestProber::new()),
        format!("127.0.0.1:{gopro}"),
        vec![format!("127.0.0.1:{osc}"), format!("127.0.0.1:{empty}")],
    );
    p.probe_once().await;
    let cams = p.current();
    assert_eq!(cams.len(), 2, "{cams:?}");
    let g = cams
        .iter()
        .find(|c| c.vendor == Some(CameraVendor::Gopro))
        .unwrap();
    assert_eq!(g.name, "HERO12 Black");
    assert_eq!(g.host, "127.0.0.1");
    assert_eq!(g.port, gopro);
    assert_eq!(g.transport, TransportKind::Http);
    assert_eq!(g.method, DiscoveryMethod::HttpProbe);
    let o = cams
        .iter()
        .find(|c| c.vendor == Some(CameraVendor::Osc))
        .unwrap();
    assert_eq!(o.name, "RICOH THETA X");
    assert_eq!(o.port, osc);

    // The GoPro goes away: only the OSC camera remains.
    let p2 = HttpCameraProbe::with_hosts(
        Arc::new(ReqwestProber::new()),
        format!("127.0.0.1:{empty}"),
        vec![format!("127.0.0.1:{osc}")],
    );
    p2.probe_once().await;
    assert_eq!(p2.current().len(), 1);
}

// MARK: - Fuji

#[tokio::test]
async fn fuji_loopback_dial_back_emits_camera() {
    let d = FujiDiscoverer::new(FujiOptions {
        listen_port: 0,
        broadcast_enabled: false,
        ..Default::default()
    });
    d.start().await.unwrap();
    let port = d.listening_port().unwrap();
    assert_ne!(port, 0);
    let mut rx = d.cameras();
    assert!(rx.borrow_and_update().is_empty());

    // A fake camera dials back.
    let mut ch = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    ch.write_all(b"NOTIFY * HTTP/1.1\r\nDSCNAME: X-T5\r\nSERVICE: PCSS/1.0\r\n\r\n")
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), rx.changed())
        .await
        .unwrap()
        .unwrap();
    let list = rx.borrow().clone();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].name, "X-T5");
    assert_eq!(list[0].host, "127.0.0.1");
    assert_eq!(list[0].vendor, Some(CameraVendor::Fujifilm));
    // The listener acknowledges the registration.
    let mut ack = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), ch.read_to_end(&mut ack))
        .await
        .unwrap()
        .unwrap();
    assert!(String::from_utf8_lossy(&ack).starts_with("HTTP/1.1 200 OK"));
    d.stop().await;
    assert_eq!(d.listening_port(), None);
}

#[tokio::test]
async fn fuji_broadcast_socket_starts() {
    let d = FujiDiscoverer::new(FujiOptions {
        listen_port: 0,
        broadcast_addresses: Some(vec!["127.255.255.255".into()]),
        ..Default::default()
    });
    d.start().await.unwrap();
    d.send_broadcast().await;
    d.stop().await;
}

// MARK: - Bonjour

#[tokio::test]
async fn bonjour_starts_and_stops() {
    let b = BonjourDiscoverer::new();
    match b.start().await {
        Ok(()) => {
            b.stop().await;
            assert!(b.current().is_empty());
        }
        Err(e) => eprintln!("skipped: mDNS unavailable: {e}"),
    }
}

// MARK: - Aggregator

/// Scripted discovery source.
#[derive(Default)]
struct FakeSource {
    state: DiscoveryState,
    fail_start: bool,
    started: AtomicBool,
    stopped: AtomicBool,
}

impl FakeSource {
    fn emit(&self, cams: Vec<DiscoveredCamera>) {
        self.state.clear();
        for c in cams {
            self.state.upsert(c);
        }
    }
}

#[async_trait]
impl CameraDiscovering for FakeSource {
    fn cameras(&self) -> tokio::sync::watch::Receiver<Vec<DiscoveredCamera>> {
        self.state.subscribe()
    }
    async fn start(&self) -> Result<(), DiscoveryError> {
        self.started.store(true, Ordering::SeqCst);
        if self.fail_start {
            return Err(DiscoveryError::Bind {
                what: "bind".into(),
                source: std::io::Error::from(std::io::ErrorKind::AddrInUse),
            });
        }
        Ok(())
    }
    async fn stop(&self) {
        self.stopped.store(true, Ordering::SeqCst);
    }
}

fn cam(id: &str, vendor: Option<CameraVendor>, host: &str) -> DiscoveredCamera {
    DiscoveredCamera::new(
        id,
        id,
        vendor,
        host,
        15740,
        DiscoveryMethod::Bonjour,
        TransportKind::PtpIp,
    )
}

#[tokio::test]
async fn aggregator_merges_dedupes_and_flags_controllable() {
    let a = Arc::new(FakeSource::default());
    let b = Arc::new(FakeSource::default());
    let agg = CameraDiscoverer::with_sources(
        vec![a.clone(), b.clone()],
        Duration::from_secs(30),
        Duration::from_secs(60),
    );
    agg.start().await.unwrap();
    a.emit(vec![
        cam("bonjour:EOS R5", Some(CameraVendor::Canon), "192.168.1.5"),
        cam(
            "bonjour:LUMIX",
            Some(CameraVendor::Panasonic),
            "192.168.1.5",
        ),
    ]);
    tokio::time::sleep(Duration::from_millis(150)).await;
    b.emit(vec![cam(
        "bonjour:EOS R5",
        Some(CameraVendor::Canon),
        "192.168.1.6",
    )]);
    tokio::time::sleep(Duration::from_millis(150)).await;
    let list = agg.current();
    assert_eq!(list.len(), 2, "{list:?}");
    let eos = list.iter().find(|c| c.id == "bonjour:EOS R5").unwrap();
    assert_eq!(
        eos.host, "192.168.1.6",
        "later sighting refreshes the address"
    );
    assert_eq!(eos.details["controllable"], "true");
    assert_eq!(eos.details["source"], "FakeSource");
    let lumix = list.iter().find(|c| c.id == "bonjour:LUMIX").unwrap();
    assert_eq!(lumix.details["controllable"], "false");
    assert_eq!(
        list[0].id, "bonjour:EOS R5",
        "controllable cameras sort first"
    );
    assert!(a.started.load(Ordering::SeqCst) && b.started.load(Ordering::SeqCst));
    agg.stop().await;
}

#[tokio::test]
async fn aggregator_expires_stale_entries() {
    let a = Arc::new(FakeSource::default());
    let agg = CameraDiscoverer::with_sources(
        vec![a.clone()],
        Duration::from_millis(300),
        Duration::from_millis(100),
    );
    agg.start().await.unwrap();
    a.emit(vec![cam("x", Some(CameraVendor::Nikon), "192.168.1.5")]);
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(agg.current().len(), 1);
    tokio::time::sleep(Duration::from_millis(700)).await;
    assert_eq!(agg.current().len(), 0);
    agg.stop().await;
}

#[tokio::test]
async fn aggregator_manual_entries_and_stream_updates() {
    let agg = CameraDiscoverer::with_sources(
        vec![],
        Duration::from_millis(200),
        Duration::from_millis(100),
    );
    agg.start().await.unwrap();
    let mut rx = agg.cameras();
    rx.borrow_and_update();
    let id = agg.add_manual(
        "192.168.1.77",
        PTPIP_STANDARD_PORT,
        Some(CameraVendor::Sony),
        None,
    );
    tokio::time::timeout(Duration::from_secs(3), rx.changed())
        .await
        .unwrap()
        .unwrap();
    let list = rx.borrow().clone();
    assert_eq!(list.len(), 1);
    let m = &list[0];
    assert_eq!(m.method, DiscoveryMethod::Manual);
    assert_eq!(m.id, "manual:192.168.1.77:15740");
    assert_eq!(m.id, id);
    assert_eq!(m.port, 15740);
    assert_eq!(m.name, "Sony");
    assert_eq!(m.transport, TransportKind::PtpIp);
    assert_eq!(m.details["controllable"], "true");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(agg.current().len(), 1, "manual entries never expire");
    agg.add_manual("192.168.0.1", 80, Some(CameraVendor::Ricoh), None);
    assert_eq!(
        agg.current()
            .iter()
            .find(|c| c.vendor == Some(CameraVendor::Ricoh))
            .map(|c| c.transport),
        Some(TransportKind::RicohHttp)
    );
    agg.add_manual(
        "10.5.5.9",
        8080,
        Some(CameraVendor::Gopro),
        Some("My GoPro"),
    );
    assert!(agg
        .current()
        .iter()
        .any(|c| c.name == "My GoPro" && c.transport == TransportKind::Http));
    agg.remove_manual(&id);
    assert_eq!(agg.current().len(), 2);
    agg.stop().await;
}

#[tokio::test]
async fn aggregator_source_start_failure_is_recorded_not_fatal() {
    let bad = Arc::new(FakeSource {
        fail_start: true,
        ..Default::default()
    });
    let good = Arc::new(FakeSource::default());
    let agg = CameraDiscoverer::with_sources(
        vec![bad.clone(), good.clone()],
        Duration::from_secs(30),
        Duration::from_secs(60),
    );
    agg.start().await.unwrap();
    good.emit(vec![cam("ok", Some(CameraVendor::Fujifilm), "192.168.1.5")]);
    assert!(wait_until(2.0, || agg.current().len() == 1).await);
    let errors = agg.last_errors();
    assert_eq!(errors.len(), 1);
    assert!(errors.values().next().unwrap().contains("bind"));
    agg.stop().await;
    assert!(bad.stopped.load(Ordering::SeqCst) && good.stopped.load(Ordering::SeqCst));
    assert_eq!(agg.current().len(), 0);
}

#[test]
fn aggregator_default_sources_construct() {
    let agg = CameraDiscoverer::default();
    assert_eq!(agg.expiry(), Duration::from_secs(30));
    assert_eq!(agg.sweep_interval(), Duration::from_secs(5));
    assert!(agg.current().is_empty());
}
