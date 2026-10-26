//! FTP/FTPS upload client for exports to the user's own server: plain FTP,
//! explicit FTPS (`AUTH TLS` + `PBSZ 0` + `PROT P`) and implicit FTPS (TLS
//! from the first byte, port 990) through tokio-rustls. Creates remote
//! directories as needed and resumes when the server already holds a prefix
//! of the file. Ported from `FTPClient.swift` + `StreamFTPClient.swift`
//! (the Apple client; SFTP is intentionally absent, as in Swift).

use std::io;
use std::net::{IpAddr, Ipv4Addr};
use std::ops::Range;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use rustls::pki_types::ServerName;
use rustls::ClientConfig;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeekExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_rustls::TlsConnector;

use super::path::FtpPath;
use super::reply::FtpReply;
use crate::net::{self, ip_filter};

/// Transport security. No SFTP case on purpose so the UI cannot offer it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
pub enum FtpSecurity {
    #[default]
    #[serde(rename = "plain")]
    Plain,
    /// `AUTH TLS` on the normal control port (21).
    #[serde(rename = "explicitTLS")]
    ExplicitTls,
    /// TLS from the first byte, conventionally port 990.
    #[serde(rename = "implicitTLS")]
    ImplicitTls,
}

impl FtpSecurity {
    pub const ALL: [FtpSecurity; 3] = [Self::Plain, Self::ExplicitTls, Self::ImplicitTls];
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FtpDestination {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: String,
    pub security: FtpSecurity,
    pub passive: bool,
    pub remote_directory: String,
}

impl FtpDestination {
    /// Port 21, anonymous, plain, passive, "/".
    pub fn new(host: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            port: 21,
            username: "anonymous".into(),
            password: String::new(),
            security: FtpSecurity::Plain,
            passive: true,
            remote_directory: "/".into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FtpClientError {
    #[error("FTP server said {code} {text}")]
    UnexpectedReply { code: u16, text: String },
    #[error("Could not connect to {0}.")]
    ConnectionFailed(String),
    #[error("FTPS is not available with this client; use the system client.")]
    TlsUnsupported,
    #[error("Malformed FTP reply: {0}")]
    MalformedReply(String),
    #[error("Could not enter or create {0}.")]
    DirectoryUnavailable(String),
    #[error("Connection timed out.")]
    Timeout,
    #[error("TLS failed: {0}")]
    Tls(String),
    #[error("Connection error: {0}")]
    Io(String),
    #[error("Could not read {0}")]
    LocalFile(String),
}

impl From<io::Error> for FtpClientError {
    fn from(e: io::Error) -> Self {
        if e.kind() == io::ErrorKind::TimedOut {
            Self::Timeout
        } else {
            Self::Io(e.to_string())
        }
    }
}

/// Upload progress: `(bytes sent so far including a resumed prefix, total)`.
pub type ProgressFn = dyn Fn(u64, u64) + Send + Sync;

/// The upload seam the export queue codes against (fakes in tests).
#[async_trait]
pub trait FtpUploading: Send + Sync {
    /// Uploads `data` to `remote_path` (relative to the destination's
    /// `remote_directory` unless absolute), creating directories as needed and
    /// resuming when the server already holds a prefix of the file.
    async fn upload(
        &self,
        data: &[u8],
        remote_path: &str,
        progress: Option<&ProgressFn>,
    ) -> Result<(), FtpClientError>;

    /// Connects, logs in and returns the banner plus FEAT summary.
    async fn test(&self) -> Result<String, FtpClientError>;
}

const CHUNK: usize = 256 * 1024;

/// FTP/FTPS client for one destination. Every call opens its own session
/// and always QUITs afterwards.
#[derive(Clone)]
pub struct FtpClient {
    destination: FtpDestination,
    timeout: Duration,
    tls: Option<Arc<ClientConfig>>,
}

impl FtpClient {
    pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(15);

    pub fn new(destination: FtpDestination) -> Self {
        Self {
            destination,
            timeout: Self::DEFAULT_TIMEOUT,
            tls: None,
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// TLS settings for FTPS (default: the system's trusted roots).
    pub fn with_tls_config(mut self, config: Arc<ClientConfig>) -> Self {
        self.tls = Some(config);
        self
    }

    pub fn destination(&self) -> &FtpDestination {
        &self.destination
    }

    /// Default rustls client config: ring provider, roots from the macOS keychain.
    pub fn system_tls_config() -> Result<Arc<ClientConfig>, FtpClientError> {
        let mut roots = rustls::RootCertStore::empty();
        for cert in rustls_native_certs::load_native_certs().certs {
            let _ = roots.add(cert);
        }
        let config =
            ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .map_err(|e| FtpClientError::Tls(e.to_string()))?
                .with_root_certificates(roots)
                .with_no_client_auth();
        Ok(Arc::new(config))
    }

    /// Opens a logged-in session (banner checked, TLS negotiated, `TYPE I`).
    pub async fn connect(&self) -> Result<FtpConnection, FtpClientError> {
        let tls = match self.destination.security {
            FtpSecurity::Plain => None,
            _ => Some(match &self.tls {
                Some(c) => c.clone(),
                None => Self::system_tls_config()?,
            }),
        };
        let mut c = FtpConnection {
            destination: self.destination.clone(),
            timeout: self.timeout,
            tls,
            control: None,
            inbox: Vec::new(),
            protect_data: false,
            banner: FtpReply {
                code: 0,
                lines: Vec::new(),
            },
        };
        c.banner = c.connect_and_login().await?;
        Ok(c)
    }

    /// Uploads bytes. See [`FtpUploading::upload`].
    pub async fn upload(
        &self,
        data: &[u8],
        remote_path: &str,
        progress: Option<&ProgressFn>,
    ) -> Result<(), FtpClientError> {
        let mut c = self.connect().await?;
        let r = c.upload(Source::Bytes(data), remote_path, progress).await;
        c.quit().await;
        r
    }

    /// Uploads a local file, streaming it from disk (exports can be large).
    pub async fn upload_file(
        &self,
        local: &Path,
        remote_path: &str,
        progress: Option<&ProgressFn>,
    ) -> Result<(), FtpClientError> {
        let file = tokio::fs::File::open(local)
            .await
            .map_err(|e| FtpClientError::LocalFile(format!("{}: {e}", local.display())))?;
        let len = file
            .metadata()
            .await
            .map_err(|e| FtpClientError::LocalFile(format!("{}: {e}", local.display())))?
            .len();
        let mut c = self.connect().await?;
        let r = c
            .upload(Source::File(file, len), remote_path, progress)
            .await;
        c.quit().await;
        r
    }

    /// Connects, logs in and returns the banner plus SYST and FEAT summary.
    pub async fn test(&self) -> Result<String, FtpClientError> {
        let mut c = self.connect().await?;
        let feat = c.command("FEAT", 200..300).await.ok();
        let syst = c.command("SYST", 200..300).await.ok();
        c.quit().await;
        let mut parts = vec![format!("{} {}", c.banner.code, c.banner.text())];
        if let Some(s) = syst {
            parts.push(s.text());
        }
        if let Some(f) = feat {
            let n = f.lines.len();
            let features: Vec<String> = f
                .lines
                .iter()
                .skip(1)
                .take(n.saturating_sub(2))
                .map(|l| l.trim().to_string())
                .collect();
            if !features.is_empty() {
                parts.push(format!("Features: {}", features.join(", ")));
            }
        }
        Ok(parts.join("\n"))
    }
}

#[async_trait]
impl FtpUploading for FtpClient {
    async fn upload(
        &self,
        data: &[u8],
        remote_path: &str,
        progress: Option<&ProgressFn>,
    ) -> Result<(), FtpClientError> {
        FtpClient::upload(self, data, remote_path, progress).await
    }

    async fn test(&self) -> Result<String, FtpClientError> {
        FtpClient::test(self).await
    }
}

// MARK: - Wire

trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}

enum Wire {
    Plain(TcpStream),
    Tls(Box<tokio_rustls::client::TlsStream<TcpStream>>),
}

impl Wire {
    fn io(&mut self) -> &mut dyn Io {
        match self {
            Wire::Plain(s) => s,
            Wire::Tls(s) => s.as_mut(),
        }
    }

    fn local_ip(&self) -> Option<IpAddr> {
        let tcp = match self {
            Wire::Plain(s) => s,
            Wire::Tls(s) => s.get_ref().0,
        };
        tcp.local_addr().ok().map(|a| a.ip())
    }
}

enum Source<'a> {
    Bytes(&'a [u8]),
    File(tokio::fs::File, u64),
}

impl Source<'_> {
    fn len(&self) -> u64 {
        match self {
            Source::Bytes(b) => b.len() as u64,
            Source::File(_, n) => *n,
        }
    }
}

/// How the data connection will be opened once the transfer command is sent.
enum PreparedData {
    /// Passive: already connected (before STOR, so servers that only answer
    /// 150 after the data connection exists don't stall us).
    Connected(TcpStream),
    /// Active: we listen, the server dials in after the transfer command.
    Listening(TcpListener),
}

/// A logged-in control connection. Exposed for diagnostics and tests;
/// [`FtpClient`] wraps the usual flows.
pub struct FtpConnection {
    destination: FtpDestination,
    timeout: Duration,
    tls: Option<Arc<ClientConfig>>,
    control: Option<Wire>,
    inbox: Vec<u8>,
    protect_data: bool,
    banner: FtpReply,
}

impl FtpConnection {
    /// The server's greeting.
    pub fn banner(&self) -> &FtpReply {
        &self.banner
    }

    fn server_name(&self) -> Result<ServerName<'static>, FtpClientError> {
        ServerName::try_from(self.destination.host.clone())
            .map_err(|e| FtpClientError::Tls(e.to_string()))
    }

    async fn tls_wrap(
        &self,
        tcp: TcpStream,
    ) -> Result<tokio_rustls::client::TlsStream<TcpStream>, FtpClientError> {
        let config = self.tls.clone().ok_or(FtpClientError::TlsUnsupported)?;
        let name = self.server_name()?;
        tokio::time::timeout(self.timeout, TlsConnector::from(config).connect(name, tcp))
            .await
            .map_err(|_| FtpClientError::Timeout)?
            .map_err(|e| FtpClientError::Tls(e.to_string()))
    }

    async fn dial(&self, host: &str, port: u16) -> Result<TcpStream, FtpClientError> {
        net::connect_tcp(host, port, self.timeout)
            .await
            .map_err(|e| match e.kind() {
                io::ErrorKind::TimedOut => FtpClientError::Timeout,
                _ => FtpClientError::ConnectionFailed(format!("{host}:{port}")),
            })
    }

    async fn connect_and_login(&mut self) -> Result<FtpReply, FtpClientError> {
        let d = self.destination.clone();
        let implicit = d.security == FtpSecurity::ImplicitTls;
        let tcp = self.dial(&d.host, d.port).await?;
        let wire = if implicit {
            Wire::Tls(Box::new(self.tls_wrap(tcp).await?))
        } else {
            Wire::Plain(tcp)
        };
        self.control = Some(wire);
        self.inbox.clear();
        self.protect_data = implicit;
        let reply = self.read_reply().await?;
        let banner = expect(reply, 200..300)?;
        if d.security == FtpSecurity::ExplicitTls {
            self.command("AUTH TLS", 200..300).await?;
            let tcp = match self.control.take() {
                Some(Wire::Plain(tcp)) => tcp,
                _ => return Err(FtpClientError::ConnectionFailed(d.host.clone())),
            };
            // Bytes buffered before the handshake would be plaintext injection.
            self.inbox.clear();
            self.control = Some(Wire::Tls(Box::new(self.tls_wrap(tcp).await?)));
            self.command("PBSZ 0", 200..300).await?;
            self.command("PROT P", 200..300).await?;
            self.protect_data = true;
        }
        let u = self
            .command(&format!("USER {}", d.username), 200..400)
            .await?;
        if u.code / 100 == 3 {
            self.command(&format!("PASS {}", d.password), 200..300)
                .await?;
        }
        self.command("TYPE I", 200..300).await?;
        Ok(banner)
    }

    /// Sends QUIT, waits up to a second for the goodbye and closes.
    pub async fn quit(&mut self) {
        let Some(mut wire) = self.control.take() else {
            return;
        };
        self.inbox.clear();
        let io = wire.io();
        if io.write_all(b"QUIT\r\n").await.is_ok() {
            let mut buf = [0u8; 512];
            let _ = tokio::time::timeout(Duration::from_secs(1), io.read(&mut buf)).await;
        }
        let _ = io.shutdown().await;
    }

    /// Sends one command line and checks the reply code is in `expecting`.
    pub async fn command(
        &mut self,
        line: &str,
        expecting: Range<u16>,
    ) -> Result<FtpReply, FtpClientError> {
        let host = self.destination.host.clone();
        let wire = self
            .control
            .as_mut()
            .ok_or(FtpClientError::ConnectionFailed(host))?;
        wire.io()
            .write_all(format!("{line}\r\n").as_bytes())
            .await?;
        let reply = self.read_reply().await?;
        expect(reply, expecting)
    }

    /// Reads one (possibly multi-line) reply.
    pub async fn read_reply(&mut self) -> Result<FtpReply, FtpClientError> {
        let mut lines: Vec<String> = Vec::new();
        let mut code: Option<u16> = None;
        loop {
            let line = self.read_line().await?;
            match code {
                None => {
                    let c: u16 = line
                        .get(..3)
                        .and_then(|s| s.parse().ok())
                        .filter(|_| line.len() >= 3)
                        .ok_or_else(|| FtpClientError::MalformedReply(line.clone()))?;
                    code = Some(c);
                    lines.push(line.get(4..).unwrap_or("").to_string());
                    if line.len() == 3 || line.as_bytes().get(3) == Some(&b' ') {
                        return Ok(FtpReply { code: c, lines });
                    }
                }
                Some(c) => {
                    let same_code = line.get(..3).and_then(|s| s.parse::<u16>().ok()) == Some(c);
                    if line.len() >= 4 && same_code && line.as_bytes().get(3) == Some(&b' ') {
                        lines.push(line.get(4..).unwrap_or("").to_string());
                        return Ok(FtpReply { code: c, lines });
                    }
                    lines.push(line);
                }
            }
        }
    }

    async fn read_line(&mut self) -> Result<String, FtpClientError> {
        let mut buf = [0u8; 4096];
        loop {
            if let Some(pos) = self.inbox.iter().position(|&b| b == b'\n') {
                let mut line: Vec<u8> = self.inbox.drain(..=pos).collect();
                line.pop();
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                return Ok(String::from_utf8_lossy(&line).into_owned());
            }
            if self.inbox.len() > 64 * 1024 {
                return Err(FtpClientError::MalformedReply("reply line too long".into()));
            }
            let host = self.destination.host.clone();
            let timeout = self.timeout;
            let wire = self
                .control
                .as_mut()
                .ok_or(FtpClientError::ConnectionFailed(host))?;
            let n = tokio::time::timeout(timeout, wire.io().read(&mut buf))
                .await
                .map_err(|_| FtpClientError::Timeout)??;
            if n == 0 {
                return Err(FtpClientError::Io("connection closed".into()));
            }
            self.inbox.extend_from_slice(&buf[..n]);
        }
    }

    // MARK: Upload

    async fn upload(
        &mut self,
        mut source: Source<'_>,
        remote_path: &str,
        progress: Option<&ProgressFn>,
    ) -> Result<(), FtpClientError> {
        let full = if remote_path.starts_with('/') {
            remote_path.to_string()
        } else {
            joined(&self.destination.remote_directory, remote_path)
        };
        let dir = FtpPath::parent(&full);
        let name = FtpPath::name(&full);
        self.ensure_directory(&dir).await?;

        let total = source.len();
        let mut offset: u64 = 0;
        if let Some(size) = self.remote_size(&name).await {
            if size == total {
                if let Some(p) = progress {
                    p(total, total);
                }
                return Ok(());
            }
            if size > 0 && size < total {
                let r = self.command(&format!("REST {size}"), 300..400).await?;
                if r.code == 350 {
                    offset = size;
                }
            }
        }
        let prepared = self.prepare_data().await?;
        self.command(&format!("STOR {name}"), 100..200).await?;
        let mut channel = self.finish_data(prepared).await?;
        if let Some(p) = progress {
            p(offset, total);
        }
        let sent: Result<(), FtpClientError> = async {
            let mut cursor = offset;
            match &mut source {
                Source::Bytes(b) => {
                    while cursor < total {
                        let end = (cursor + CHUNK as u64).min(total);
                        channel
                            .io()
                            .write_all(&b[cursor as usize..end as usize])
                            .await?;
                        cursor = end;
                        if let Some(p) = progress {
                            p(cursor, total);
                        }
                    }
                }
                Source::File(f, _) => {
                    f.seek(io::SeekFrom::Start(offset))
                        .await
                        .map_err(|e| FtpClientError::LocalFile(e.to_string()))?;
                    let mut buf = vec![0u8; CHUNK];
                    while cursor < total {
                        let n = f
                            .read(&mut buf)
                            .await
                            .map_err(|e| FtpClientError::LocalFile(e.to_string()))?;
                        if n == 0 {
                            break;
                        }
                        channel.io().write_all(&buf[..n]).await?;
                        cursor += n as u64;
                        if let Some(p) = progress {
                            p(cursor, total);
                        }
                    }
                }
            }
            // TLS close_notify, then FIN: the server's EOF ends the file.
            channel.io().shutdown().await?;
            Ok(())
        }
        .await;
        drop(channel);
        sent?;
        let reply = self.read_reply().await?;
        expect(reply, 200..300)?;
        Ok(())
    }

    async fn ensure_directory(&mut self, dir: &str) -> Result<(), FtpClientError> {
        self.command("CWD /", 200..300).await?;
        for c in FtpPath::components(dir) {
            if self.command(&format!("CWD {c}"), 200..300).await.is_ok() {
                continue;
            }
            let _ = self.command(&format!("MKD {c}"), 200..300).await;
            if self.command(&format!("CWD {c}"), 200..300).await.is_err() {
                return Err(FtpClientError::DirectoryUnavailable(dir.to_string()));
            }
        }
        Ok(())
    }

    async fn remote_size(&mut self, name: &str) -> Option<u64> {
        let r = self.command(&format!("SIZE {name}"), 200..300).await.ok()?;
        r.lines.first()?.trim().parse().ok()
    }

    /// Passive: EPSV, falling back to PASV, and connects. Active: listens and
    /// announces it with PORT (EPRT for IPv6).
    async fn prepare_data(&mut self) -> Result<PreparedData, FtpClientError> {
        if self.destination.passive {
            let mut host = self.destination.host.clone();
            let epsv = self
                .command("EPSV", 200..300)
                .await
                .ok()
                .and_then(|r| FtpReply::parse_epsv(&r.text()));
            let port = match epsv {
                Some(p) => p,
                None => {
                    let p = self.command("PASV", 200..300).await?;
                    let (h, port) = FtpReply::parse_pasv(&p.text())
                        .ok_or_else(|| FtpClientError::MalformedReply(p.text()))?;
                    // Servers behind NAT often advertise a private/zero address; trust the control host then.
                    if h != "0.0.0.0" && ip_filter::is_usable(&h) {
                        host = h;
                    }
                    port
                }
            };
            Ok(PreparedData::Connected(self.dial(&host, port).await?))
        } else {
            let listener = net::bind_tcp_listener(Ipv4Addr::UNSPECIFIED, 0, 1)?;
            let port = listener.local_addr()?.port();
            let local = self
                .control
                .as_ref()
                .and_then(Wire::local_ip)
                .unwrap_or(IpAddr::V4(Ipv4Addr::LOCALHOST));
            match local {
                IpAddr::V4(v4) => {
                    let h = v4.to_string().replace('.', ",");
                    self.command(&format!("PORT {h},{},{}", port >> 8, port & 0xFF), 200..300)
                        .await?;
                }
                IpAddr::V6(v6) => {
                    self.command(&format!("EPRT |2|{v6}|{port}|"), 200..300)
                        .await?;
                }
            }
            Ok(PreparedData::Listening(listener))
        }
    }

    async fn finish_data(&self, prepared: PreparedData) -> Result<Wire, FtpClientError> {
        let tcp = match prepared {
            PreparedData::Connected(s) => s,
            PreparedData::Listening(l) => {
                let (s, _) = tokio::time::timeout(self.timeout, l.accept())
                    .await
                    .map_err(|_| FtpClientError::Timeout)??;
                s
            }
        };
        let _ = tcp.set_nodelay(true);
        if self.protect_data {
            Ok(Wire::Tls(Box::new(self.tls_wrap(tcp).await?)))
        } else {
            Ok(Wire::Plain(tcp))
        }
    }
}

fn expect(reply: FtpReply, range: Range<u16>) -> Result<FtpReply, FtpClientError> {
    if range.contains(&reply.code) {
        Ok(reply)
    } else {
        Err(FtpClientError::UnexpectedReply {
            code: reply.code,
            text: reply.text(),
        })
    }
}

fn joined(base: &str, rel: &str) -> String {
    let b = base.strip_suffix('/').unwrap_or(base);
    let prefix = if b.is_empty() {
        String::new()
    } else if b.starts_with('/') {
        b.to_string()
    } else {
        format!("/{b}")
    };
    format!("{prefix}/{rel}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn joins_remote_paths() {
        assert_eq!(joined("/", "a.jpg"), "/a.jpg");
        assert_eq!(joined("/Tether/", "2026/a.jpg"), "/Tether/2026/a.jpg");
        assert_eq!(joined("Tether", "a.jpg"), "/Tether/a.jpg");
        assert_eq!(joined("", "a.jpg"), "/a.jpg");
    }

    #[test]
    fn no_sftp_option() {
        let names: Vec<String> = FtpSecurity::ALL
            .iter()
            .map(|s| serde_json::to_string(s).unwrap())
            .collect();
        assert_eq!(names, ["\"plain\"", "\"explicitTLS\"", "\"implicitTLS\""]);
        assert!(!names.iter().any(|n| n.to_lowercase().contains("sftp")));
    }

    #[test]
    fn system_tls_config_builds() {
        assert!(FtpClient::system_tls_config().is_ok());
    }
}
