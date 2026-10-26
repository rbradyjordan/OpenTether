//! Minimal HTTP GET seam so discovery (Ricoh props, GoPro/OSC info, SSDP
//! device descriptions) can be unit-tested with canned responses.
//! Ported from `HTTPProbing.swift`.

use std::time::Duration;

use async_trait::async_trait;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProbeError {
    #[error("Invalid URL {0}")]
    InvalidUrl(String),
    #[error("Request timed out")]
    Timeout,
    #[error("HTTP request failed: {0}")]
    Transport(String),
}

/// One HTTP GET.
#[async_trait]
pub trait HttpProbing: Send + Sync {
    /// Returns body and HTTP status. Errors on transport failure or timeout.
    async fn get(&self, url: &str, timeout: Duration) -> Result<(Vec<u8>, u16), ProbeError>;
}

/// The real prober: an ephemeral reqwest client (rustls, no proxy, no cache).
#[derive(Clone)]
pub struct ReqwestProber {
    client: reqwest::Client,
}

impl Default for ReqwestProber {
    fn default() -> Self {
        Self::new()
    }
}

impl ReqwestProber {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap_or_default();
        Self { client }
    }
}

#[async_trait]
impl HttpProbing for ReqwestProber {
    async fn get(&self, url: &str, timeout: Duration) -> Result<(Vec<u8>, u16), ProbeError> {
        let parsed =
            reqwest::Url::parse(url).map_err(|_| ProbeError::InvalidUrl(url.to_string()))?;
        let map = |e: reqwest::Error| {
            if e.is_timeout() {
                ProbeError::Timeout
            } else {
                ProbeError::Transport(e.to_string())
            }
        };
        let resp = self
            .client
            .get(parsed)
            .timeout(timeout)
            .send()
            .await
            .map_err(map)?;
        let status = resp.status().as_u16();
        let body = resp.bytes().await.map_err(map)?;
        Ok((body.to_vec(), status))
    }
}
