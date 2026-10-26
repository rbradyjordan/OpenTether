//! FTPS: explicit (`AUTH TLS`) and implicit TLS uploads against a scripted
//! TLS FTP server on loopback with a self-signed certificate, including a
//! protected (`PROT P`) data channel.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tether_net::{FtpClient, FtpClientError, FtpDestination, FtpSecurity};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::{TlsAcceptor, TlsConnector};

trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}

fn provider() -> Arc<rustls::crypto::CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// Self-signed cert for 127.0.0.1 + the matching server and client configs.
fn tls_pair() -> (TlsAcceptor, Arc<rustls::ClientConfig>) {
    let ck =
        rcgen::generate_simple_self_signed(vec!["127.0.0.1".to_string(), "localhost".to_string()])
            .unwrap();
    let cert: CertificateDer<'static> = ck.cert.der().clone();
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(ck.key_pair.serialize_der()));
    let server = rustls::ServerConfig::builder_with_provider(provider())
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![cert.clone()], key)
        .unwrap();
    let mut roots = rustls::RootCertStore::empty();
    roots.add(cert).unwrap();
    let client = rustls::ClientConfig::builder_with_provider(provider())
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(roots)
        .with_no_client_auth();
    (TlsAcceptor::from(Arc::new(server)), Arc::new(client))
}

/// Reads one line from a plain socket without over-reading (pre-TLS).
async fn read_plain_line(s: &mut TcpStream) -> String {
    let mut out = Vec::new();
    let mut b = [0u8; 1];
    while s.read(&mut b).await.unwrap() == 1 {
        if b[0] == b'\n' {
            break;
        }
        out.push(b[0]);
    }
    String::from_utf8_lossy(&out).trim_end().to_string()
}

#[derive(Default)]
struct Log {
    commands: Vec<String>,
    stored: Vec<u8>,
}

/// One scripted FTPS session; records commands and the stored bytes.
async fn fake_ftps_server(implicit: bool, acceptor: TlsAcceptor, log: Arc<Mutex<Log>>) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (mut tcp, _) = listener.accept().await.unwrap();
        let control: Box<dyn Io> = if implicit {
            let Ok(mut tls) = acceptor.accept(tcp).await else {
                return;
            };
            tls.write_all(b"220 fake FTPS\r\n").await.unwrap();
            Box::new(tls)
        } else {
            tcp.write_all(b"220 fake FTPS\r\n").await.unwrap();
            let auth = read_plain_line(&mut tcp).await;
            log.lock().unwrap().commands.push(auth.clone());
            assert_eq!(auth, "AUTH TLS");
            tcp.write_all(b"234 Proceed with negotiation.\r\n")
                .await
                .unwrap();
            Box::new(acceptor.accept(tcp).await.unwrap())
        };
        let (r, mut w) = tokio::io::split(control);
        let mut lines = BufReader::new(r).lines();
        let mut passive: Option<TcpListener> = None;
        while let Ok(Some(line)) = lines.next_line().await {
            log.lock().unwrap().commands.push(line.clone());
            let verb = line.split(' ').next().unwrap_or("").to_uppercase();
            let reply: String = match verb.as_str() {
                "PBSZ" | "PROT" | "TYPE" => "200 OK".into(),
                "USER" => "331 Password please".into(),
                "PASS" => "230 Logged in".into(),
                "FEAT" => "211-Features:\r\n AUTH TLS\r\n PBSZ\r\n PROT\r\n211 End".into(),
                "SYST" => "215 UNIX Type: L8".into(),
                "CWD" | "MKD" => "250 OK".into(),
                "SIZE" => "550 No such file".into(),
                "EPSV" => {
                    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
                    let p = l.local_addr().unwrap().port();
                    passive = Some(l);
                    format!("229 Entering Extended Passive Mode (|||{p}|)")
                }
                "STOR" => {
                    w.write_all(b"150 Ok to send data.\r\n").await.unwrap();
                    let l = passive.take().unwrap();
                    let (d, _) = l.accept().await.unwrap();
                    let mut d = acceptor.accept(d).await.unwrap();
                    let mut data = Vec::new();
                    d.read_to_end(&mut data).await.unwrap();
                    log.lock().unwrap().stored = data;
                    "226 Transfer complete.".into()
                }
                "QUIT" => {
                    let _ = w.write_all(b"221 Goodbye.\r\n").await;
                    return;
                }
                _ => "500 Unknown".into(),
            };
            w.write_all(format!("{reply}\r\n").as_bytes())
                .await
                .unwrap();
        }
    });
    port
}

fn destination(port: u16, security: FtpSecurity) -> FtpDestination {
    FtpDestination {
        host: "127.0.0.1".into(),
        port,
        username: "me".into(),
        password: "pw".into(),
        security,
        passive: true,
        remote_directory: "/exports".into(),
    }
}

#[tokio::test]
async fn explicit_ftps_upload_with_protected_data() {
    let (acceptor, client_cfg) = tls_pair();
    let log = Arc::new(Mutex::new(Log::default()));
    let port = fake_ftps_server(false, acceptor, log.clone()).await;
    let payload: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    FtpClient::new(destination(port, FtpSecurity::ExplicitTls))
        .with_tls_config(client_cfg)
        .with_timeout(Duration::from_secs(5))
        .upload(&payload, "IMG_1.JPG", None)
        .await
        .unwrap();
    let log = log.lock().unwrap();
    assert_eq!(log.stored, payload);
    let cmds: Vec<&str> = log.commands.iter().map(String::as_str).collect();
    assert_eq!(&cmds[..4], ["AUTH TLS", "PBSZ 0", "PROT P", "USER me"]);
    assert!(cmds.contains(&"PASS pw"));
    assert!(cmds.contains(&"STOR IMG_1.JPG"));
    assert_eq!(cmds.last(), Some(&"QUIT"));
}

#[tokio::test]
async fn implicit_ftps_test_summary() {
    let (acceptor, client_cfg) = tls_pair();
    let log = Arc::new(Mutex::new(Log::default()));
    let port = fake_ftps_server(true, acceptor, log.clone()).await;
    let summary = FtpClient::new(destination(port, FtpSecurity::ImplicitTls))
        .with_tls_config(client_cfg)
        .test()
        .await
        .unwrap();
    assert!(summary.starts_with("220 fake FTPS"), "{summary}");
    assert!(summary.contains("Features: AUTH TLS, PBSZ, PROT"));
    assert!(!log.lock().unwrap().commands.iter().any(|c| c == "AUTH TLS"));
}

#[tokio::test]
async fn untrusted_certificate_is_rejected() {
    let (acceptor, _) = tls_pair();
    let (_, other_client) = tls_pair(); // trusts a different self-signed cert
    let log = Arc::new(Mutex::new(Log::default()));
    let port = fake_ftps_server(true, acceptor, log).await;
    let r = FtpClient::new(destination(port, FtpSecurity::ImplicitTls))
        .with_tls_config(other_client)
        .with_timeout(Duration::from_secs(3))
        .test()
        .await;
    assert!(matches!(r, Err(FtpClientError::Tls(_))), "{r:?}");
}

/// Sanity check that the scripted server really speaks TLS on the data path.
#[tokio::test]
async fn tls_connector_round_trip() {
    let (acceptor, client_cfg) = tls_pair();
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        let (s, _) = l.accept().await.unwrap();
        let mut t = acceptor.accept(s).await.unwrap();
        t.write_all(b"hi").await.unwrap();
        t.shutdown().await.unwrap();
    });
    let s = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let name = rustls::pki_types::ServerName::try_from("127.0.0.1").unwrap();
    let mut t = TlsConnector::from(client_cfg)
        .connect(name, s)
        .await
        .unwrap();
    let mut out = String::new();
    t.read_to_string(&mut out).await.unwrap();
    assert_eq!(out, "hi");
}
