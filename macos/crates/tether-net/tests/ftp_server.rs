//! Loopback tests of the FTP server with our own client, ported from the
//! Swift `FTPServerTests` (plus symlink escapes, RETR and file uploads).

mod common;

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::{fake_jpeg, wait_until};
use tether_net::ftp::{FtpListing, ProgressFn};
use tether_net::{
    FtpClient, FtpClientError, FtpConnection, FtpDestination, FtpReply, FtpSecurity, FtpServer,
    FtpServerConfig, FtpServerEvent, ReceivedFile,
};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::UnboundedReceiver;

struct Harness {
    root: tempfile::TempDir,
    server: FtpServer,
    events: Arc<Mutex<Vec<FtpServerEvent>>>,
    files: UnboundedReceiver<ReceivedFile>,
}

impl Harness {
    async fn start(anonymous: bool, idle: Duration, heartbeat: Duration) -> Self {
        let root = tempfile::tempdir().unwrap();
        let mut cfg = FtpServerConfig::new(root.path().join("inbox"));
        cfg.port = 0;
        cfg.username = "cam".into();
        cfg.password = "secret".into();
        cfg.allow_anonymous = anonymous;
        cfg.passive_port_range = 42000..=42020;
        cfg.idle_timeout = idle;
        cfg.heartbeat_interval = heartbeat;
        let server = FtpServer::new(cfg);
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut rx = server.events();
        let sink = events.clone();
        tokio::spawn(async move {
            while let Ok(e) = rx.recv().await {
                sink.lock().unwrap().push(e);
            }
        });
        let files = server.take_received_files().unwrap();
        assert!(server.take_received_files().is_none());
        let port = server.start().await.unwrap();
        assert!(server.is_running());
        assert_eq!(server.bound_port(), Some(port));
        Self {
            root,
            server,
            events,
            files,
        }
    }

    async fn default() -> Self {
        Self::start(false, Duration::from_secs(300), Duration::from_secs(5)).await
    }

    fn inbox(&self) -> std::path::PathBuf {
        self.root.path().join("inbox")
    }

    fn port(&self) -> u16 {
        self.server.bound_port().unwrap()
    }

    fn destination(&self, user: &str, password: &str, passive: bool, dir: &str) -> FtpDestination {
        FtpDestination {
            host: "127.0.0.1".into(),
            port: self.port(),
            username: user.into(),
            password: password.into(),
            security: FtpSecurity::Plain,
            passive,
            remote_directory: dir.into(),
        }
    }

    fn client(&self) -> FtpClient {
        FtpClient::new(self.destination("cam", "secret", true, "/"))
            .with_timeout(Duration::from_secs(5))
    }

    async fn connect(&self) -> FtpConnection {
        self.client().connect().await.unwrap()
    }

    fn events(&self) -> Vec<FtpServerEvent> {
        self.events.lock().unwrap().clone()
    }

    fn count(&self, f: impl Fn(&FtpServerEvent) -> bool) -> usize {
        self.events().iter().filter(|e| f(e)).count()
    }

    async fn wait_event(&self, f: impl Fn(&FtpServerEvent) -> bool) -> bool {
        wait_until(5.0, || self.events().iter().any(&f)).await
    }
}

async fn code(c: &mut FtpConnection, cmd: &str) -> u16 {
    match c.command(cmd, 100..400).await {
        Ok(r) => r.code,
        Err(FtpClientError::UnexpectedReply { code, .. }) => code,
        Err(e) => panic!("{cmd}: {e}"),
    }
}

async fn text(c: &mut FtpConnection, cmd: &str) -> String {
    c.command(cmd, 200..400).await.unwrap().text()
}

/// PASV, `command` (expects 150), connect, run `body`, close, final reply.
async fn data_transfer<F, Fut>(c: &mut FtpConnection, command: &str, body: F) -> FtpReply
where
    F: FnOnce(TcpStream) -> Fut,
    Fut: std::future::Future<Output = ()>,
{
    let pasv = c.command("PASV", 200..300).await.unwrap();
    let (host, port) = FtpReply::parse_pasv(&pasv.text()).unwrap();
    assert_eq!(host, "127.0.0.1");
    let prelim = c.command(command, 100..200).await.unwrap();
    assert_eq!(prelim.code, 150);
    let s = TcpStream::connect((host.as_str(), port)).await.unwrap();
    body(s).await;
    c.read_reply().await.unwrap()
}

async fn send_and_close(mut s: TcpStream, bytes: Vec<u8>) {
    s.write_all(&bytes).await.unwrap();
    s.shutdown().await.unwrap();
}

async fn receive_all(mut s: TcpStream) -> Vec<u8> {
    let mut out = Vec::new();
    s.read_to_end(&mut out).await.unwrap();
    out
}

type Recorded = Arc<Mutex<Vec<(u64, u64)>>>;

fn recorder() -> (Recorded, Box<ProgressFn>) {
    let values = Arc::new(Mutex::new(Vec::new()));
    let v = values.clone();
    (values, Box::new(move |a, b| v.lock().unwrap().push((a, b))))
}

#[tokio::test]
async fn banner_login_success_and_failure() {
    let h = Harness::default().await;
    let mut ok = h.connect().await;
    assert_eq!(ok.banner().code, 220);
    assert!(ok.banner().text().contains("Tether FTP ready"));
    assert_eq!(text(&mut ok, "SYST").await, "UNIX Type: L8");
    let feat = ok.command("FEAT", 200..300).await.unwrap();
    assert!(feat.lines.iter().any(|l| l.contains("REST STREAM")));
    assert!(feat.lines.iter().any(|l| l.contains("EPSV")));
    assert_eq!(code(&mut ok, "OPTS UTF8 ON").await, 200);
    assert_eq!(code(&mut ok, "NOOP").await, 200);
    assert_eq!(code(&mut ok, "TYPE I").await, 200);
    assert!(text(&mut ok, "PWD").await.contains("\"/\""));
    assert_eq!(code(&mut ok, "BOGUS").await, 500);
    assert_eq!(h.server.connected_clients(), 1);
    ok.quit().await;

    let bad = FtpClient::new(h.destination("cam", "wrong", true, "/"));
    match bad.connect().await {
        Err(e) => assert_eq!(
            e,
            FtpClientError::UnexpectedReply {
                code: 530,
                text: "Login incorrect".into()
            }
        ),
        Ok(_) => panic!("login should fail"),
    }
    assert!(
        h.wait_event(|e| matches!(e, FtpServerEvent::LoginFailed(_)))
            .await
    );

    // Commands before login are refused; three bad passwords end the session.
    let s = TcpStream::connect(("127.0.0.1", h.port())).await.unwrap();
    let (r, mut w) = s.into_split();
    let mut lines = BufReader::new(r).lines();
    assert!(lines.next_line().await.unwrap().unwrap().starts_with("220"));
    w.write_all(b"PWD\r\n").await.unwrap();
    assert_eq!(
        lines.next_line().await.unwrap().unwrap(),
        "530 Please log in"
    );
    w.write_all(b"PASS x\r\n").await.unwrap();
    assert_eq!(
        lines.next_line().await.unwrap().unwrap(),
        "503 Login with USER first"
    );
    for _ in 0..3 {
        w.write_all(b"USER cam\r\nPASS nope\r\n").await.unwrap();
        assert!(lines.next_line().await.unwrap().unwrap().starts_with("331"));
        assert_eq!(
            lines.next_line().await.unwrap().unwrap(),
            "530 Login incorrect"
        );
    }
    assert_eq!(
        lines.next_line().await.unwrap(),
        None,
        "dropped after 3 failures"
    );
}

#[tokio::test]
async fn anonymous_policy() {
    let h = Harness::default().await;
    let anon = FtpClient::new(h.destination("anonymous", "x@y", true, "/"));
    match anon.connect().await {
        Err(FtpClientError::UnexpectedReply { code, .. }) => assert_eq!(code, 530),
        Err(e) => panic!("{e}"),
        Ok(_) => panic!("anonymous must be rejected"),
    }
    let h2 = Harness::start(true, Duration::from_secs(300), Duration::from_secs(5)).await;
    let mut c = FtpClient::new(h2.destination("anonymous", "x@y", true, "/"))
        .connect()
        .await
        .unwrap();
    assert_eq!(code(&mut c, "PWD").await, 257);
    c.quit().await;
}

#[tokio::test]
async fn passive_stor_one_mib_via_client() {
    let mut h = Harness::default().await;
    let payload = fake_jpeg(1 << 20);
    let (progress, cb) = recorder();
    h.client()
        .upload(&payload, "IMG_0001.JPG", Some(cb.as_ref()))
        .await
        .unwrap();
    let saved = std::fs::read(h.inbox().join("IMG_0001.JPG")).unwrap();
    assert_eq!(saved, payload);
    assert!(!h.inbox().join("IMG_0001.JPG.part").exists());
    let n = payload.len() as u64;
    assert_eq!(progress.lock().unwrap().last().copied(), Some((n, n)));

    let file = tokio::time::timeout(Duration::from_secs(5), h.files.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(file.path.file_name().unwrap(), "IMG_0001.JPG");
    assert_eq!(file.virtual_path, "/IMG_0001.JPG");
    assert_eq!(file.size, n);
    assert_eq!(file.client, "127.0.0.1");
    assert!(file.path.starts_with(h.inbox()));
    assert!(
        h.wait_event(|e| matches!(e, FtpServerEvent::FileReceived { bytes, .. } if *bytes == n))
            .await
    );
    assert!(h.events().iter().any(
        |e| matches!(e, FtpServerEvent::TransferStarted { path, .. } if path == "/IMG_0001.JPG")
    ));
}

#[tokio::test]
async fn nested_mkd_and_stor() {
    let h = Harness::default().await;
    let payload = fake_jpeg(5000);
    FtpClient::new(h.destination("cam", "secret", true, "/Tether"))
        .upload(&payload, "2026/10/16/DSC_0042.NEF", None)
        .await
        .unwrap();
    assert_eq!(
        std::fs::read(h.inbox().join("Tether/2026/10/16/DSC_0042.NEF")).unwrap(),
        payload
    );

    // Cameras also issue a single MKD with a deep path.
    let mut c = h.connect().await;
    assert_eq!(code(&mut c, "MKD 2026/10/17/A").await, 257);
    assert_eq!(code(&mut c, "CWD 2026/10/17/A").await, 250);
    assert!(text(&mut c, "PWD").await.contains("/2026/10/17/A"));
    assert_eq!(code(&mut c, "CDUP").await, 250);
    assert!(text(&mut c, "PWD").await.contains("\"/2026/10/17\""));
    assert_eq!(code(&mut c, "RMD A").await, 250);
    match c.command("CWD A", 200..300).await {
        Err(e) => assert_eq!(
            e,
            FtpClientError::UnexpectedReply {
                code: 550,
                text: "Failed to change directory".into()
            }
        ),
        Ok(_) => panic!("CWD into a removed directory"),
    }
    // A non-empty directory is not removed.
    assert_eq!(code(&mut c, "CWD /").await, 250);
    assert_eq!(code(&mut c, "RMD Tether").await, 550);
    c.quit().await;
}

#[tokio::test]
async fn rest_and_appe_resume() {
    let h = Harness::default().await;
    let payload = fake_jpeg(300_000);
    let half = payload.len() / 2;
    let mut c = h.connect().await;

    // First half as a complete STOR (a camera that got cut off wrote what it had).
    let first = payload[..half].to_vec();
    let done = data_transfer(&mut c, "STOR part.jpg", |s| send_and_close(s, first)).await;
    assert_eq!(done.code, 226);
    assert_eq!(text(&mut c, "SIZE part.jpg").await, half.to_string());

    // REST + STOR writes the remainder at the offset.
    assert_eq!(code(&mut c, &format!("REST {half}")).await, 350);
    let rest = payload[half..].to_vec();
    let done = data_transfer(&mut c, "STOR part.jpg", |s| send_and_close(s, rest)).await;
    assert_eq!(done.code, 226);
    assert_eq!(std::fs::read(h.inbox().join("part.jpg")).unwrap(), payload);

    // APPE appends.
    let done = data_transfer(&mut c, "STOR appe.bin", |s| {
        send_and_close(s, b"hello ".to_vec())
    })
    .await;
    assert_eq!(done.code, 226);
    let done = data_transfer(&mut c, "APPE appe.bin", |s| {
        send_and_close(s, b"world".to_vec())
    })
    .await;
    assert_eq!(done.code, 226);
    assert_eq!(
        std::fs::read_to_string(h.inbox().join("appe.bin")).unwrap(),
        "hello world"
    );

    // MDTM / DELE / RNFR+RNTO.
    assert_eq!(text(&mut c, "MDTM appe.bin").await.len(), 14);
    assert_eq!(code(&mut c, "RNFR appe.bin").await, 350);
    assert_eq!(code(&mut c, "RNTO renamed.bin").await, 250);
    assert_eq!(code(&mut c, "RNTO again.bin").await, 503);
    assert_eq!(code(&mut c, "DELE renamed.bin").await, 250);
    assert!(!h.inbox().join("renamed.bin").exists());
    assert_eq!(code(&mut c, "REST abc").await, 501);
    c.quit().await;
}

#[tokio::test]
async fn retr_downloads_with_offset() {
    let h = Harness::default().await;
    let payload = fake_jpeg(100_000);
    std::fs::write(h.inbox().join("get.jpg"), &payload).unwrap();
    let mut c = h.connect().await;
    let got = Arc::new(Mutex::new(Vec::new()));
    let g = got.clone();
    let done = data_transfer(&mut c, "RETR get.jpg", |s| async move {
        *g.lock().unwrap() = receive_all(s).await;
    })
    .await;
    assert_eq!(done.code, 226);
    assert_eq!(*got.lock().unwrap(), payload);
    assert_eq!(code(&mut c, "REST 1000").await, 350);
    let g = got.clone();
    data_transfer(&mut c, "RETR get.jpg", |s| async move {
        *g.lock().unwrap() = receive_all(s).await;
    })
    .await;
    assert_eq!(*got.lock().unwrap(), payload[1000..]);
    assert_eq!(code(&mut c, "RETR missing.jpg").await, 550);
    c.quit().await;
}

#[tokio::test]
async fn client_resumes_when_server_has_prefix() {
    let mut h = Harness::default().await;
    let payload = fake_jpeg(200_000);
    std::fs::write(h.inbox().join("resume.jpg"), &payload[..80_000]).unwrap();
    let (progress, cb) = recorder();
    h.client()
        .upload(&payload, "resume.jpg", Some(cb.as_ref()))
        .await
        .unwrap();
    assert_eq!(
        std::fs::read(h.inbox().join("resume.jpg")).unwrap(),
        payload
    );
    assert_eq!(
        progress.lock().unwrap().first().map(|p| p.0),
        Some(80_000),
        "progress starts at the resume offset"
    );
    let file = tokio::time::timeout(Duration::from_secs(5), h.files.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(file.size, 120_000, "only the remainder crossed the wire");
    // Identical file: client skips the transfer entirely.
    let (progress, cb) = recorder();
    h.client()
        .upload(&payload, "resume.jpg", Some(cb.as_ref()))
        .await
        .unwrap();
    assert_eq!(*progress.lock().unwrap(), [(200_000, 200_000)]);
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(h.files.try_recv().is_err());
}

#[tokio::test]
async fn path_escapes_rejected() {
    let h = Harness::default().await;
    // A sibling of the root that an escape would hit.
    std::fs::write(h.root.path().join("secret.txt"), b"keep out").unwrap();
    let mut c = h.connect().await;
    assert_eq!(code(&mut c, "CWD ..").await, 550);
    assert_eq!(code(&mut c, "CWD /../../").await, 550);
    assert_eq!(code(&mut c, "MKD ../escape").await, 550);
    assert_eq!(code(&mut c, "STOR ../../evil.txt").await, 553);
    assert_eq!(code(&mut c, "STOR ../evil.txt").await, 553);
    assert_eq!(code(&mut c, "DELE ../secret.txt").await, 550);
    assert_eq!(code(&mut c, "SIZE ../secret.txt").await, 550);
    assert_eq!(code(&mut c, "RETR ../secret.txt").await, 550);
    assert_eq!(code(&mut c, "RNFR ../secret.txt").await, 550);
    assert_eq!(code(&mut c, "LIST ../..").await, 550);
    assert_eq!(code(&mut c, "STOR a\\..\\..\\evil.txt").await, 553);
    assert!(!h.root.path().join("escape").exists());
    assert!(!h.root.path().join("evil.txt").exists());
    assert!(h.root.path().join("secret.txt").exists());
    // Still at root and still usable.
    assert!(text(&mut c, "PWD").await.contains("\"/\""));
    c.quit().await;
}

#[cfg(unix)]
#[tokio::test]
async fn symlinks_inside_root_cannot_escape() {
    let h = Harness::default().await;
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("private.txt"), b"x").unwrap();
    std::os::unix::fs::symlink(outside.path(), h.inbox().join("link")).unwrap();
    let mut c = h.connect().await;
    assert_eq!(code(&mut c, "CWD link").await, 550);
    assert_eq!(code(&mut c, "SIZE link/private.txt").await, 550);
    assert_eq!(code(&mut c, "DELE link/private.txt").await, 550);
    assert_eq!(code(&mut c, "MKD link/new").await, 550);
    assert_eq!(code(&mut c, "PASV").await, 227);
    assert_eq!(code(&mut c, "STOR link/evil.jpg").await, 553);
    assert!(!outside.path().join("evil.jpg").exists());
    assert!(!outside.path().join("new").exists());
    assert!(outside.path().join("private.txt").exists());
    c.quit().await;
}

#[tokio::test]
async fn list_output_parses() {
    let h = Harness::default().await;
    std::fs::create_dir_all(h.inbox().join("2026")).unwrap();
    std::fs::write(h.inbox().join("a b.jpg"), vec![7u8; 1234]).unwrap();
    std::fs::write(h.inbox().join("stale.jpg.part"), b"").unwrap();
    let mut c = h.connect().await;
    let listing = Arc::new(Mutex::new(Vec::new()));
    let l = listing.clone();
    let done = data_transfer(&mut c, "LIST -la", |s| async move {
        *l.lock().unwrap() = receive_all(s).await;
    })
    .await;
    assert_eq!(done.code, 226);
    let body = String::from_utf8(listing.lock().unwrap().clone()).unwrap();
    let lines: Vec<&str> = body.split("\r\n").filter(|l| !l.is_empty()).collect();
    assert_eq!(lines.len(), 2, "{lines:?}");
    let parsed: Vec<_> = lines
        .iter()
        .filter_map(|l| FtpListing::parse_line(l))
        .collect();
    assert_eq!(parsed.len(), 2);
    assert_eq!(
        parsed.iter().find(|p| p.0 == "a b.jpg").map(|p| p.2),
        Some(1234)
    );
    assert_eq!(
        parsed.iter().find(|p| p.0 == "2026").map(|p| p.1),
        Some(true)
    );

    let names = Arc::new(Mutex::new(Vec::new()));
    let n = names.clone();
    data_transfer(&mut c, "NLST", |s| async move {
        *n.lock().unwrap() = receive_all(s).await;
    })
    .await;
    assert_eq!(
        String::from_utf8(names.lock().unwrap().clone()).unwrap(),
        "2026\r\na b.jpg\r\n"
    );
    c.quit().await;
}

#[tokio::test]
async fn epsv_works() {
    let h = Harness::default().await;
    let mut c = h.connect().await;
    let epsv = c.command("EPSV", 200..300).await.unwrap();
    assert_eq!(epsv.code, 229);
    let port = FtpReply::parse_epsv(&epsv.text()).unwrap();
    let payload = fake_jpeg(20_000);
    assert_eq!(code(&mut c, "STOR epsv.jpg").await, 150);
    let s = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    send_and_close(s, payload.clone()).await;
    assert_eq!(c.read_reply().await.unwrap().code, 226);
    assert_eq!(std::fs::read(h.inbox().join("epsv.jpg")).unwrap(), payload);
    // STOR without a data connection set up is refused.
    assert_eq!(code(&mut c, "STOR nodata.jpg").await, 425);
    c.quit().await;
}

#[tokio::test]
async fn active_mode_upload() {
    let h = Harness::default().await;
    let payload = fake_jpeg(70_000);
    FtpClient::new(h.destination("cam", "secret", false, "/"))
        .upload(&payload, "active.jpg", None)
        .await
        .unwrap();
    assert_eq!(
        std::fs::read(h.inbox().join("active.jpg")).unwrap(),
        payload
    );
    // EPRT form as well.
    let mut c = h.connect().await;
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    assert_eq!(
        code(&mut c, &format!("EPRT |1|127.0.0.1|{port}|")).await,
        200
    );
    assert_eq!(code(&mut c, "STOR eprt.bin").await, 150);
    let (s, _) = tokio::time::timeout(Duration::from_secs(3), l.accept())
        .await
        .unwrap()
        .unwrap();
    send_and_close(s, b"eprt".to_vec()).await;
    assert_eq!(c.read_reply().await.unwrap().code, 226);
    assert_eq!(
        std::fs::read_to_string(h.inbox().join("eprt.bin")).unwrap(),
        "eprt"
    );
    assert_eq!(code(&mut c, "PORT 1,2,3").await, 501);
    assert_eq!(code(&mut c, "EPRT ||").await, 501);
    c.quit().await;
}

#[tokio::test]
async fn two_concurrent_clients() {
    let mut h = Harness::default().await;
    let a = fake_jpeg(600_000);
    let b = fake_jpeg(400_000);
    let dest = h.destination("cam", "secret", true, "/");
    let (ca, cb) = (FtpClient::new(dest.clone()), FtpClient::new(dest.clone()));
    let (ra, rb) = tokio::join!(
        ca.upload(&a, "cam1/A.JPG", None),
        cb.upload(&b, "cam2/B.JPG", None),
    );
    ra.unwrap();
    rb.unwrap();
    assert_eq!(std::fs::read(h.inbox().join("cam1/A.JPG")).unwrap(), a);
    assert_eq!(std::fs::read(h.inbox().join("cam2/B.JPG")).unwrap(), b);
    let mut got = Vec::new();
    for _ in 0..2 {
        got.push(
            tokio::time::timeout(Duration::from_secs(5), h.files.recv())
                .await
                .unwrap()
                .unwrap()
                .virtual_path,
        );
    }
    got.sort();
    assert_eq!(got, ["/cam1/A.JPG", "/cam2/B.JPG"]);
    assert!(
        wait_until(5.0, || h
            .count(|e| matches!(e, FtpServerEvent::ClientDisconnected(_)))
            == 2)
        .await
    );
    assert_eq!(h.server.connected_clients(), 0);
}

#[tokio::test]
async fn upload_file_streams_from_disk() {
    let h = Harness::default().await;
    let payload = fake_jpeg(700_000);
    let local = h.root.path().join("export.jpg");
    std::fs::write(&local, &payload).unwrap();
    // A prefix on the server: the file upload resumes too.
    std::fs::create_dir_all(h.inbox().join("exports")).unwrap();
    std::fs::write(h.inbox().join("exports/export.jpg"), &payload[..300_000]).unwrap();
    let (progress, cb) = recorder();
    h.client()
        .upload_file(&local, "exports/export.jpg", Some(cb.as_ref()))
        .await
        .unwrap();
    assert_eq!(
        std::fs::read(h.inbox().join("exports/export.jpg")).unwrap(),
        payload
    );
    let p = progress.lock().unwrap().clone();
    assert_eq!(p.first(), Some(&(300_000, 700_000)));
    assert_eq!(p.last(), Some(&(700_000, 700_000)));
    let missing = h
        .client()
        .upload_file(Path::new("/nonexistent/x.jpg"), "x.jpg", None)
        .await;
    assert!(matches!(missing, Err(FtpClientError::LocalFile(_))));
}

#[tokio::test]
async fn client_test_reports_banner_and_features() {
    let h = Harness::default().await;
    let summary = h.client().test().await.unwrap();
    assert!(summary.contains("220 Tether FTP ready"), "{summary}");
    assert!(summary.contains("UNIX Type: L8"));
    assert!(summary.contains("Features: UTF8, SIZE, MDTM, REST STREAM"));
    // Explicit FTPS against a server without TLS fails at AUTH TLS.
    let mut d = h.destination("cam", "secret", true, "/");
    d.security = FtpSecurity::ExplicitTls;
    match FtpClient::new(d).test().await {
        Err(FtpClientError::UnexpectedReply { code, .. }) => assert_eq!(code, 530),
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn connection_refused_is_reported() {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    drop(l);
    let mut d = FtpDestination::new("127.0.0.1");
    d.port = port;
    match FtpClient::new(d).test().await {
        Err(FtpClientError::ConnectionFailed(s)) => assert!(s.contains(&port.to_string())),
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
async fn idle_clients_are_dropped() {
    let h = Harness::start(
        false,
        Duration::from_millis(400),
        Duration::from_millis(100),
    )
    .await;
    let mut c = h.connect().await;
    assert_eq!(h.server.connected_clients(), 1);
    assert!(
        h.wait_event(|e| matches!(e, FtpServerEvent::ClientDisconnected(_)))
            .await
    );
    assert_eq!(h.server.connected_clients(), 0);
    assert!(h
        .events()
        .iter()
        .any(|e| matches!(e, FtpServerEvent::Error(m) if m.starts_with("Dropping idle client"))));
    assert!(
        c.command("NOOP", 200..300).await.is_err(),
        "connection should be gone"
    );
}

#[tokio::test]
async fn rebind_keeps_port_and_stop_emits() {
    let h = Harness::default().await;
    let port = h.port();
    h.server.rebind().await;
    assert_eq!(h.server.bound_port(), Some(port));
    assert!(h.server.is_running());
    assert!(
        h.wait_event(|e| matches!(e, FtpServerEvent::Rebound { .. }))
            .await
    );
    let mut c = h.connect().await;
    assert_eq!(code(&mut c, "NOOP").await, 200);
    c.quit().await;
    h.server.stop();
    assert!(!h.server.is_running());
    assert!(h.wait_event(|e| matches!(e, FtpServerEvent::Stopped)).await);
    assert!(h
        .events()
        .iter()
        .any(|e| matches!(e, FtpServerEvent::Started { port: p, .. } if *p == port)));
    // Port is free again.
    tokio::time::sleep(Duration::from_millis(50)).await;
    let again = std::net::TcpListener::bind(("0.0.0.0", port));
    assert!(again.is_ok());
}
