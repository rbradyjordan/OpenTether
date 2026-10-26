//! Shared test helpers: a canned HTTP prober and a tiny local HTTP server.
#![allow(dead_code)]

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tether_net::{HttpProbing, ProbeError};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Canned HTTP responder keyed by absolute URL (404 when unknown).
#[derive(Default)]
pub struct FakeProber {
    responses: Mutex<HashMap<String, (Vec<u8>, u16)>>,
    pub error: Mutex<Option<ProbeError>>,
    calls: AtomicUsize,
}

impl FakeProber {
    pub fn new(responses: &[(&str, &[u8], u16)]) -> Arc<Self> {
        let p = Self::default();
        for (u, b, s) in responses {
            p.set(u, b, *s);
        }
        Arc::new(p)
    }

    pub fn set(&self, url: &str, body: &[u8], status: u16) {
        self.responses
            .lock()
            .unwrap()
            .insert(url.to_string(), (body.to_vec(), status));
    }

    pub fn set_error(&self, e: Option<ProbeError>) {
        *self.error.lock().unwrap() = e;
    }

    pub fn call_count(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl HttpProbing for FakeProber {
    async fn get(&self, url: &str, _timeout: Duration) -> Result<(Vec<u8>, u16), ProbeError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if let Some(e) = self.error.lock().unwrap().clone() {
            return Err(e);
        }
        Ok(self
            .responses
            .lock()
            .unwrap()
            .get(url)
            .cloned()
            .unwrap_or((Vec::new(), 404)))
    }
}

/// Serves `routes` (path → body, always 200) on `bind`:0; returns the port.
pub async fn http_server(bind: &str, routes: Vec<(&'static str, Vec<u8>)>) -> u16 {
    let listener = TcpListener::bind((bind, 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let routes: Arc<HashMap<&'static str, Vec<u8>>> = Arc::new(routes.into_iter().collect());
    tokio::spawn(async move {
        loop {
            let Ok((mut s, _)) = listener.accept().await else {
                return;
            };
            let routes = routes.clone();
            tokio::spawn(async move {
                let mut req = Vec::new();
                let mut buf = [0u8; 2048];
                while !req.windows(4).any(|w| w == b"\r\n\r\n") {
                    match s.read(&mut buf).await {
                        Ok(0) | Err(_) => return,
                        Ok(n) => req.extend_from_slice(&buf[..n]),
                    }
                }
                let text = String::from_utf8_lossy(&req);
                let path = text.split(' ').nth(1).unwrap_or("/").to_string();
                let (status, body) = match routes.get(path.as_str()) {
                    Some(b) => ("200 OK", b.clone()),
                    None => ("404 Not Found", b"nope".to_vec()),
                };
                let head = format!(
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = s.write_all(head.as_bytes()).await;
                let _ = s.write_all(&body).await;
                let _ = s.shutdown().await;
            });
        }
    });
    port
}

/// Deterministic pseudo-JPEG payload.
pub fn fake_jpeg(size: usize) -> Vec<u8> {
    let mut v = Vec::with_capacity(size);
    v.extend_from_slice(&[0xFF, 0xD8, 0xFF, 0xE0]);
    let mut x: u32 = 0x1234_5678;
    while v.len() < size.saturating_sub(2) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        v.push((x & 0xFF) as u8);
    }
    v.extend_from_slice(&[0xFF, 0xD9]);
    v.truncate(size);
    v
}

/// Polls `f` until it is true or `secs` pass.
pub async fn wait_until(secs: f64, mut f: impl FnMut() -> bool) -> bool {
    let deadline = tokio::time::Instant::now() + Duration::from_secs_f64(secs);
    while tokio::time::Instant::now() < deadline {
        if f() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    f()
}
