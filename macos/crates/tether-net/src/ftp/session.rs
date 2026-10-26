//! One FTP control connection. Sequential command loop; data connections are
//! opened per transfer (PASV/EPSV listener or PORT/EPRT dial-out).
//! Ported from `FTPSession.swift`; replies are identical.

use std::io;
use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use tokio::fs::{File, OpenOptions};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};

use super::path::{FtpListing, FtpPath};
use super::server::{FtpServerEvent, ReceivedFile, ServerInner, SessionActivity};
use crate::net::connect_tcp;

/// Longest command line we buffer before dropping the client.
const MAX_LINE: usize = 64 * 1024;
const PASSIVE_ACCEPT_TIMEOUT: Duration = Duration::from_secs(20);
const ACTIVE_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const PROGRESS_EVERY: u64 = 1 << 20;
const CHUNK: usize = 256 * 1024;

enum DataMode {
    None,
    Passive(TcpListener),
    Active(String, u16),
}

/// What a command handler wants next: keep reading or end the session.
type Flow = io::Result<bool>;

pub(crate) struct Session {
    peer: String,
    server: Arc<ServerInner>,
    activity: Arc<SessionActivity>,
    reader: OwnedReadHalf,
    writer: OwnedWriteHalf,
    local_ip: Option<IpAddr>,
    inbox: Vec<u8>,
    pending_user: Option<String>,
    authenticated: bool,
    failed_logins: u32,
    cwd: String,
    rest_offset: u64,
    rename_from: Option<String>,
    data_mode: DataMode,
}

impl Session {
    pub(crate) fn new(
        stream: TcpStream,
        peer: String,
        server: Arc<ServerInner>,
        activity: Arc<SessionActivity>,
    ) -> Self {
        let _ = stream.set_nodelay(true);
        let local_ip = stream.local_addr().ok().map(|a| a.ip());
        let (reader, writer) = stream.into_split();
        Self {
            peer,
            server,
            activity,
            reader,
            writer,
            local_ip,
            inbox: Vec::new(),
            pending_user: None,
            authenticated: false,
            failed_logins: 0,
            cwd: "/".into(),
            rest_offset: 0,
            rename_from: None,
            data_mode: DataMode::None,
        }
    }

    pub(crate) async fn run(mut self) {
        if self.reply("220 Tether FTP ready").await.is_err() {
            return;
        }
        while let Some(line) = self.read_line().await {
            self.activity.touch();
            match self.handle(&line).await {
                Ok(true) => continue,
                _ => break,
            }
        }
        let _ = self.writer.shutdown().await;
    }

    /// `None` at EOF, on a read error or when a line exceeds [`MAX_LINE`].
    async fn read_line(&mut self) -> Option<String> {
        let mut buf = [0u8; 8192];
        loop {
            if let Some(pos) = self.inbox.iter().position(|&b| b == b'\n') {
                let mut line: Vec<u8> = self.inbox.drain(..=pos).collect();
                line.pop();
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                return Some(crate::net::decode_text(&line));
            }
            if self.inbox.len() > MAX_LINE {
                return None;
            }
            match self.reader.read(&mut buf).await {
                Ok(0) | Err(_) => return None,
                Ok(n) => self.inbox.extend_from_slice(&buf[..n]),
            }
        }
    }

    async fn reply(&mut self, text: &str) -> io::Result<()> {
        self.writer
            .write_all(format!("{text}\r\n").as_bytes())
            .await
    }

    async fn reply_lines(&mut self, lines: &[&str]) -> io::Result<()> {
        let mut out = lines.join("\r\n");
        out.push_str("\r\n");
        self.writer.write_all(out.as_bytes()).await
    }

    async fn handle(&mut self, line: &str) -> Flow {
        let trimmed = line.trim_matches(|c| c == ' ' || c == '\t');
        if trimmed.is_empty() {
            return Ok(true);
        }
        let (verb, arg) = match trimmed.split_once(' ') {
            Some((v, a)) => (v.to_uppercase(), a.trim_matches(|c| c == ' ' || c == '\t')),
            None => (trimmed.to_uppercase(), ""),
        };
        let arg = arg.to_string();
        match verb.as_str() {
            "USER" => self.user(&arg).await.map(|_| true),
            "PASS" => self.pass(&arg).await,
            "QUIT" => {
                self.reply("221 Goodbye").await?;
                Ok(false)
            }
            "SYST" => self.reply("215 UNIX Type: L8").await.map(|_| true),
            "FEAT" => self
                .reply_lines(&[
                    "211-Features:",
                    " UTF8",
                    " SIZE",
                    " MDTM",
                    " REST STREAM",
                    " EPSV",
                    " EPRT",
                    " PASV",
                    "211 End",
                ])
                .await
                .map(|_| true),
            "OPTS" => {
                if arg.to_uppercase().starts_with("UTF8") {
                    self.reply("200 UTF8 mode enabled").await?;
                } else {
                    self.reply("501 Option not understood").await?;
                }
                Ok(true)
            }
            "NOOP" => self.reply("200 OK").await.map(|_| true),
            _ if !self.authenticated => self.reply("530 Please log in").await.map(|_| true),
            _ => self.handle_authenticated(&verb, &arg).await.map(|_| true),
        }
    }

    fn is_anonymous_name(&self, name: &str) -> bool {
        self.server.config.allow_anonymous
            && ["anonymous", "ftp"].contains(&name.to_lowercase().as_str())
    }

    async fn user(&mut self, name: &str) -> io::Result<()> {
        self.pending_user = Some(name.to_string());
        if self.is_anonymous_name(name) {
            self.authenticated = true;
            self.reply("230 Anonymous login ok").await
        } else {
            self.reply(&format!("331 Password required for {name}"))
                .await
        }
    }

    async fn pass(&mut self, password: &str) -> Flow {
        let Some(name) = self.pending_user.clone() else {
            self.reply("503 Login with USER first").await?;
            return Ok(true);
        };
        if self.is_anonymous_name(&name) {
            self.authenticated = true;
            self.reply("230 Anonymous login ok").await?;
            return Ok(true);
        }
        let cfg = &self.server.config;
        if name == cfg.username && password == cfg.password {
            self.authenticated = true;
            self.reply(&format!("230 User {name} logged in")).await?;
            Ok(true)
        } else {
            self.failed_logins += 1;
            self.server
                .emit(FtpServerEvent::LoginFailed(self.peer.clone()));
            self.reply("530 Login incorrect").await?;
            Ok(self.failed_logins < 3)
        }
    }

    async fn handle_authenticated(&mut self, verb: &str, arg: &str) -> io::Result<()> {
        match verb {
            "PWD" | "XPWD" => {
                let quoted = self.cwd.replace('"', "\"\"");
                self.reply(&format!("257 \"{quoted}\" is the current directory"))
                    .await
            }
            "CWD" | "XCWD" => {
                let target = if arg.is_empty() { "/" } else { arg };
                match self.resolve(target) {
                    Some(v) if self.is_directory(&v).await => {
                        self.cwd = v.clone();
                        self.reply(&format!("250 Directory changed to {v}")).await
                    }
                    _ => self.reply("550 Failed to change directory").await,
                }
            }
            "CDUP" | "XCUP" => {
                self.cwd = FtpPath::parent(&self.cwd);
                let msg = format!("250 Directory changed to {}", self.cwd);
                self.reply(&msg).await
            }
            "TYPE" => {
                let t = if arg.is_empty() {
                    "I".to_string()
                } else {
                    arg.to_uppercase()
                };
                self.reply(&format!("200 Type set to {t}")).await
            }
            "MODE" => {
                let r = if arg.eq_ignore_ascii_case("S") {
                    "200 Mode S ok"
                } else {
                    "504 Only stream mode is supported"
                };
                self.reply(r).await
            }
            "STRU" => {
                let r = if arg.eq_ignore_ascii_case("F") {
                    "200 Structure F ok"
                } else {
                    "504 Only file structure is supported"
                };
                self.reply(r).await
            }
            "PASV" => self.pasv(false).await,
            "EPSV" => self.pasv(true).await,
            "PORT" => self.port(arg).await,
            "EPRT" => self.eprt(arg).await,
            "STOR" => self.store(arg, false).await,
            "APPE" => self.store(arg, true).await,
            "REST" => match arg.parse::<u64>() {
                Ok(n) => {
                    self.rest_offset = n;
                    self.reply(&format!("350 Restarting at {n}. Send STORE or RETRIEVE"))
                        .await
                }
                Err(_) => self.reply("501 Bad restart point").await,
            },
            "LIST" => self.list(arg, false).await,
            "NLST" => self.list(arg, true).await,
            "MLSD" => self.reply("502 MLSD not implemented").await,
            "MKD" | "XMKD" => {
                let created = match self.resolve(arg).filter(|v| v != "/") {
                    Some(v) => match self.disk(&v) {
                        Some(p) if tokio::fs::create_dir_all(&p).await.is_ok() => Some(v),
                        _ => None,
                    },
                    None => None,
                };
                match created {
                    Some(v) => self.reply(&format!("257 \"{v}\" created")).await,
                    None => self.reply("550 Create directory failed").await,
                }
            }
            "RMD" | "XRMD" => {
                let ok = match self.resolve(arg).filter(|v| v != "/") {
                    Some(v) if self.is_directory(&v).await => match self.disk(&v) {
                        // `remove_dir` only succeeds on an empty directory.
                        Some(p) => tokio::fs::remove_dir(&p).await.is_ok(),
                        None => false,
                    },
                    _ => false,
                };
                if ok {
                    self.reply("250 Directory removed").await
                } else {
                    self.reply("550 Remove directory failed").await
                }
            }
            "DELE" => {
                let ok = match self.resolve(arg) {
                    Some(v) if self.is_file(&v).await => match self.disk(&v) {
                        Some(p) => tokio::fs::remove_file(&p).await.is_ok(),
                        None => false,
                    },
                    _ => false,
                };
                if ok {
                    self.reply("250 File deleted").await
                } else {
                    self.reply("550 Delete failed").await
                }
            }
            "RNFR" => match self.resolve(arg) {
                Some(v) if self.exists(&v).await => {
                    self.rename_from = Some(v);
                    self.reply("350 Ready for RNTO").await
                }
                _ => self.reply("550 File not found").await,
            },
            "RNTO" => {
                let Some(from) = self.rename_from.take() else {
                    return self.reply("503 RNFR required first").await;
                };
                let paths = self
                    .resolve(arg)
                    .and_then(|to| Some((self.disk(&from)?, self.disk(&to)?)));
                let ok = match paths {
                    Some((from, to)) => {
                        // Replace an existing file; never delete a directory tree.
                        if tokio::fs::metadata(&to).await.map(|m| m.is_file()).unwrap_or(false)
                        {
                            let _ = tokio::fs::remove_file(&to).await;
                        }
                        tokio::fs::rename(&from, &to).await.is_ok()
                    }
                    None => false,
                };
                if ok {
                    self.reply("250 Rename successful").await
                } else {
                    self.reply("550 Rename failed").await
                }
            }
            "SIZE" => {
                let size = match self.resolve(arg) {
                    Some(v) if self.is_file(&v).await => self.metadata(&v).await.map(|m| m.len()),
                    _ => None,
                };
                match size {
                    Some(n) => self.reply(&format!("213 {n}")).await,
                    None => self.reply("550 Could not get file size").await,
                }
            }
            "MDTM" => {
                let modified = match self.resolve(arg) {
                    Some(v) => self.metadata(&v).await.and_then(|m| m.modified().ok()),
                    None => None,
                };
                match modified {
                    Some(t) => {
                        let s = FtpListing::mdtm_string(DateTime::<Utc>::from(t));
                        self.reply(&format!("213 {s}")).await
                    }
                    None => {
                        self.reply("550 Could not get file modification time")
                            .await
                    }
                }
            }
            "ABOR" => {
                self.data_mode = DataMode::None;
                self.reply("226 No transfer to abort").await
            }
            "ALLO" => self.reply("202 No storage allocation necessary").await,
            "RETR" => self.retrieve(arg).await,
            "HELP" => self.reply("214 Tether FTP: USER PASS QUIT SYST FEAT OPTS PWD CWD CDUP TYPE PASV EPSV PORT EPRT STOR APPE REST LIST NLST MKD RMD DELE RNFR RNTO SIZE MDTM ABOR NOOP RETR").await,
            _ => self.reply("500 Unknown command").await,
        }
    }

    // MARK: Paths

    fn resolve(&self, arg: &str) -> Option<String> {
        FtpPath::resolve(arg, &self.cwd)
    }

    /// Sandboxed on-disk path; `None` when the virtual path would leave the root.
    fn disk(&self, virtual_path: &str) -> Option<PathBuf> {
        FtpPath::sandboxed(&self.server.config.root_directory, virtual_path)
    }

    async fn metadata(&self, virtual_path: &str) -> Option<std::fs::Metadata> {
        tokio::fs::metadata(self.disk(virtual_path)?).await.ok()
    }

    async fn exists(&self, v: &str) -> bool {
        self.metadata(v).await.is_some()
    }

    async fn is_directory(&self, v: &str) -> bool {
        self.metadata(v).await.map(|m| m.is_dir()).unwrap_or(false)
    }

    async fn is_file(&self, v: &str) -> bool {
        self.metadata(v).await.map(|m| !m.is_dir()).unwrap_or(false)
    }

    // MARK: Data connections

    async fn pasv(&mut self, extended: bool) -> io::Result<()> {
        self.data_mode = DataMode::None;
        let l = match self.server.make_passive_listener() {
            Ok(l) => l,
            Err(_) => return self.reply("425 Can't open passive port").await,
        };
        let port = match l.local_addr() {
            Ok(a) => a.port(),
            Err(_) => return self.reply("425 Can't open passive port").await,
        };
        self.data_mode = DataMode::Passive(l);
        if extended {
            return self
                .reply(&format!("229 Entering Extended Passive Mode (|||{port}|)"))
                .await;
        }
        match self.local_ip {
            Some(IpAddr::V4(v4)) => {
                let h = v4.to_string().replace('.', ",");
                self.reply(&format!(
                    "227 Entering Passive Mode ({h},{},{})",
                    port >> 8,
                    port & 0xFF
                ))
                .await
            }
            _ => self.reply("425 Use EPSV for this connection").await,
        }
    }

    async fn port(&mut self, arg: &str) -> io::Result<()> {
        let parts: Vec<u16> = arg
            .split(',')
            .filter_map(|p| p.trim().parse().ok())
            .collect();
        if parts.len() != 6 || parts.iter().any(|&p| p > 255) {
            return self.reply("501 Bad PORT argument").await;
        }
        let host = format!("{}.{}.{}.{}", parts[0], parts[1], parts[2], parts[3]);
        self.data_mode = DataMode::Active(host, (parts[4] << 8) | parts[5]);
        self.reply("200 PORT command successful").await
    }

    async fn eprt(&mut self, arg: &str) -> io::Result<()> {
        // |1|h.h.h.h|port| or |2|ipv6|port|
        let Some(delim) = arg.chars().next() else {
            return self.reply("501 Bad EPRT argument").await;
        };
        let parts: Vec<&str> = arg.split(delim).collect();
        let parsed = (parts.len() >= 5 && !parts[2].is_empty())
            .then(|| parts[3].parse::<u16>().ok())
            .flatten();
        let Some(port) = parsed else {
            return self.reply("501 Bad EPRT argument").await;
        };
        self.data_mode = DataMode::Active(parts[2].to_string(), port);
        self.reply("200 EPRT command successful").await
    }

    async fn open_data_connection(&mut self) -> io::Result<TcpStream> {
        match std::mem::replace(&mut self.data_mode, DataMode::None) {
            DataMode::None => Err(io::Error::new(io::ErrorKind::NotConnected, "no data mode")),
            DataMode::Passive(l) => {
                let (s, _) = tokio::time::timeout(PASSIVE_ACCEPT_TIMEOUT, l.accept())
                    .await
                    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "passive accept"))??;
                Ok(s)
            }
            DataMode::Active(host, port) => connect_tcp(&host, port, ACTIVE_CONNECT_TIMEOUT).await,
        }
    }

    // MARK: Transfers

    async fn store(&mut self, arg: &str, append: bool) -> io::Result<()> {
        let offset = std::mem::take(&mut self.rest_offset);
        let target = if arg.is_empty() {
            None
        } else {
            self.resolve(arg)
        };
        let v = match target {
            Some(v) if v != "/" && !self.is_directory(&v).await => v,
            _ => return self.reply("553 Invalid file name").await,
        };
        let Some(final_path) = self.disk(&v) else {
            return self.reply("553 Invalid file name").await;
        };
        if !self.is_directory(&FtpPath::parent(&v)).await {
            return self.reply("550 Directory does not exist").await;
        }
        if matches!(self.data_mode, DataMode::None) {
            return self.reply("425 Use PASV or PORT first").await;
        }

        let mut part_os = final_path.clone().into_os_string();
        part_os.push(".part");
        let part = PathBuf::from(part_os);
        // Resume/append targets: the final file when it exists, else the leftover .part.
        let final_exists = tokio::fs::metadata(&final_path).await.is_ok();
        let resume_target = if final_exists {
            final_path.clone()
        } else {
            part.clone()
        };
        let write_path = if append || offset > 0 {
            resume_target
        } else {
            part
        };
        let mut file = match open_for_write(&write_path, append, offset).await {
            Ok(f) => f,
            Err(_) => return self.reply("553 Could not open file for writing").await,
        };

        self.reply(&format!(
            "150 Opening BINARY mode data connection for {}",
            FtpPath::name(&v)
        ))
        .await?;
        let mut data = match self.open_data_connection().await {
            Ok(d) => d,
            Err(_) => return self.reply("425 Can't open data connection").await,
        };
        self.activity.set_transferring(true);
        self.server.emit(FtpServerEvent::TransferStarted {
            path: v.clone(),
            from: self.peer.clone(),
        });
        let started = Instant::now();
        let mut received: u64 = 0;
        let mut since_progress: u64 = 0;
        let mut buf = vec![0u8; CHUNK];
        let failure: Option<io::Error> = loop {
            let n = match data.read(&mut buf).await {
                Ok(0) => break None, // EOF: the client finished.
                Ok(n) => n,
                Err(e) => break Some(e),
            };
            if let Err(e) = file.write_all(&buf[..n]).await {
                break Some(e);
            }
            received += n as u64;
            since_progress += n as u64;
            self.activity.touch();
            if since_progress >= PROGRESS_EVERY {
                since_progress = 0;
                self.server.emit(FtpServerEvent::TransferProgress {
                    path: v.clone(),
                    bytes: received,
                });
            }
        };
        self.activity.set_transferring(false);
        drop(data);
        let _ = file.flush().await;
        let _ = file.sync_all().await;
        drop(file);
        if let Some(e) = failure {
            self.server.emit(FtpServerEvent::Error(format!(
                "Transfer of {v} failed: {e}"
            )));
            return self.reply("426 Connection closed; transfer aborted").await;
        }
        if write_path != final_path {
            if let Err(e) = tokio::fs::rename(&write_path, &final_path).await {
                self.server.emit(FtpServerEvent::Error(format!(
                    "Could not finalize {v}: {e}"
                )));
                return self.reply("451 Could not finalize file").await;
            }
        }
        self.reply("226 Transfer complete").await?;
        let duration = started.elapsed();
        self.server.emit(FtpServerEvent::FileReceived {
            path: final_path.clone(),
            bytes: received,
            from: self.peer.clone(),
            duration,
        });
        self.server.deliver(ReceivedFile {
            path: final_path,
            virtual_path: v,
            size: received,
            client: self.peer.clone(),
            duration,
        });
        Ok(())
    }

    async fn retrieve(&mut self, arg: &str) -> io::Result<()> {
        let offset = std::mem::take(&mut self.rest_offset);
        let path = match self.resolve(arg) {
            Some(v) if self.is_file(&v).await => self.disk(&v),
            _ => None,
        };
        let file = match path {
            Some(p) => File::open(p).await.ok(),
            None => None,
        };
        let Some(mut file) = file else {
            return self.reply("550 File not found").await;
        };
        let _ = file.seek(io::SeekFrom::Start(offset)).await;
        self.reply("150 Opening BINARY mode data connection")
            .await?;
        let mut data = match self.open_data_connection().await {
            Ok(d) => d,
            Err(_) => return self.reply("425 Can't open data connection").await,
        };
        self.activity.set_transferring(true);
        let mut buf = vec![0u8; CHUNK];
        let result: io::Result<()> = async {
            loop {
                let n = file.read(&mut buf).await?;
                if n == 0 {
                    break;
                }
                data.write_all(&buf[..n]).await?;
                self.activity.touch();
            }
            data.shutdown().await
        }
        .await;
        self.activity.set_transferring(false);
        drop(data);
        match result {
            Ok(()) => self.reply("226 Transfer complete").await,
            Err(_) => self.reply("426 Connection closed; transfer aborted").await,
        }
    }

    async fn list(&mut self, arg: &str, names_only: bool) -> io::Result<()> {
        // Ignore ls flags like "-la".
        let target = arg
            .split(' ')
            .find(|t| !t.is_empty() && !t.starts_with('-'))
            .unwrap_or(".");
        let Some(v) = self.resolve(target) else {
            return self.reply("550 No such directory").await;
        };
        let lines: Vec<String> = if self.is_directory(&v).await {
            let Some(dir) = self.disk(&v) else {
                return self.reply("550 No such directory").await;
            };
            let now = Utc::now();
            FtpListing::entries(&dir)
                .await
                .into_iter()
                .filter(|e| !e.name.ends_with(".part"))
                .map(|e| {
                    if names_only {
                        e.name
                    } else {
                        FtpListing::line(&e, now)
                    }
                })
                .collect()
        } else if self.is_file(&v).await {
            let name = FtpPath::name(&v);
            let parent = self.disk(&FtpPath::parent(&v));
            let entries = match parent {
                Some(p) => FtpListing::entries(&p).await,
                None => Vec::new(),
            };
            entries
                .into_iter()
                .filter(|e| e.name == name)
                .map(|e| {
                    if names_only {
                        e.name
                    } else {
                        FtpListing::line(&e, Utc::now())
                    }
                })
                .collect()
        } else {
            return self.reply("550 No such file or directory").await;
        };
        self.reply("150 Here comes the directory listing").await?;
        let mut data = match self.open_data_connection().await {
            Ok(d) => d,
            Err(_) => return self.reply("425 Can't open data connection").await,
        };
        let result: io::Result<()> = async {
            if !lines.is_empty() {
                let mut body = lines.join("\r\n");
                body.push_str("\r\n");
                data.write_all(body.as_bytes()).await?;
            }
            data.shutdown().await
        }
        .await;
        drop(data);
        match result {
            Ok(()) => self.reply("226 Directory send OK").await,
            Err(_) => self.reply("426 Connection closed; transfer aborted").await,
        }
    }
}

/// Opens the STOR target: appending at the end, or truncated to `offset`
/// and positioned there (REST resume, 0 = overwrite).
async fn open_for_write(path: &PathBuf, append: bool, offset: u64) -> io::Result<File> {
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .await?;
    if append {
        file.seek(io::SeekFrom::End(0)).await?;
    } else {
        file.set_len(offset).await?;
        file.seek(io::SeekFrom::Start(offset)).await?;
    }
    Ok(file)
}
